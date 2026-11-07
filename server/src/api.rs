//! `/crucible/v1`: hello and pairing for anyone on the home network or tailnet, everything else for paired devices
//! only, each request also carrying the person's own Plex token for this server.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::{Config, Policy};
use crate::jobs::{Jobs, State as JobState};
use crate::net::{classify, Peer};
use crate::pairing::{new_device_token, Pairings, Refused};
use crate::plex::{sanitize_key, Plex, PlexError};
use crate::recap::Writer;
use crate::segments;
use crate::store::{hash_token, Device, Store};

pub const PROTOCOL: u32 = 1;
const ACCEPTED_FOR: Duration = Duration::from_secs(600);
const MAX_WAIT: Duration = Duration::from_secs(25);

/// Everything a request may need.
pub struct AppState {
    pub config: Arc<Config>,
    pub store: Arc<Store>,
    pub pairings: Arc<Pairings>,
    pub fingerprint: String,
    pub plex: Plex,
    pub writer: Option<Arc<Writer>>,
    pub jobs: Jobs,
    pub owner_token_hash: Option<String>,
    accepted: Mutex<HashMap<String, Instant>>,
}

impl AppState {
    pub fn new(
        config: Arc<Config>,
        store: Arc<Store>,
        pairings: Arc<Pairings>,
        fingerprint: String,
        plex: Plex,
        writer: Option<Arc<Writer>>,
        owner_token: Option<&str>,
    ) -> Self {
        AppState {
            config,
            store,
            pairings,
            fingerprint,
            plex,
            writer,
            jobs: Jobs::default(),
            owner_token_hash: owner_token.map(hash_token),
            accepted: Mutex::new(HashMap::new()),
        }
    }
}

type Shared = Arc<AppState>;

/// An error as every Midgar service writes it: a code, a sentence and what to do.
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    hint: Option<&'static str>,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        ApiError { status, code, message: message.into(), hint: None }
    }

    fn hint(mut self, hint: &'static str) -> Self {
        self.hint = Some(hint);
        self
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({"error": {"code": self.code, "message": self.message, "hint": self.hint}}))).into_response()
    }
}

impl From<PlexError> for ApiError {
    fn from(error: PlexError) -> Self {
        match error {
            PlexError::Unauthorized => ApiError::new(StatusCode::FORBIDDEN, "plex_refused", "Plex does not let this account see that."),
            PlexError::NotFound(_) => ApiError::new(StatusCode::NOT_FOUND, "not_found", "Plex has no such item."),
            other => {
                ApiError::new(StatusCode::BAD_GATEWAY, "plex_unreachable", other.to_string()).hint("Check that Plex Media Server is running on this machine.")
            }
        }
    }
}

/// Who is asking: a paired device on behalf of a Plex account.
struct Caller {
    device: Device,
    plex_token: String,
    person: String,
}

pub fn router(state: Shared) -> Router {
    let v1 = Router::new()
        .route("/hello", get(hello))
        .route("/pair", post(pair))
        .route("/pair/confirm", post(pair_confirm))
        .route("/devices", get(devices))
        .route("/devices/{id}", delete(remove_device))
        .route("/brain", get(brain))
        .route("/segments/{rating_key}", get(segments_for))
        .route("/recaps", post(start_recap))
        .route("/recaps/{id}", get(collect))
        .route("/questions", post(start_question))
        .route("/questions/{id}", get(collect));
    Router::new()
        .nest("/crucible/v1", v1)
        .layer(DefaultBodyLimit::max(1 << 20))
        .layer(middleware::from_fn(only_nearby))
        .layer(middleware::from_fn(protocol_header))
        .with_state(state)
}

async fn only_nearby(ConnectInfo(address): ConnectInfo<SocketAddr>, request: Request, next: Next) -> Response {
    if classify(address.ip()) == Peer::Outside {
        return ApiError::new(StatusCode::FORBIDDEN, "outside", "Crucible Server answers only this machine, the home network and your tailnet.")
            .into_response();
    }
    next.run(request).await
}

async fn protocol_header(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert("Crucible-Protocol", PROTOCOL.into());
    response
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers.get("authorization")?.to_str().ok()?.strip_prefix("Bearer ").map(str::trim)
}

fn device_of(state: &AppState, headers: &HeaderMap) -> Result<Device, ApiError> {
    let token = bearer(headers).ok_or_else(|| {
        ApiError::new(StatusCode::UNAUTHORIZED, "not_paired", "This device is not paired.").hint("Pair it in Crucible: Settings, Crucible Server.")
    })?;
    state.store.device_for_token(token).map_err(|error| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "database", error.to_string()))?.ok_or_else(|| {
        ApiError::new(StatusCode::UNAUTHORIZED, "not_paired", "This device is not paired any more.")
            .hint("Pair it again in Crucible: Settings, Crucible Server.")
    })
}

/// A paired device plus a Plex token this Plex server accepts, within the owner's policy.
async fn caller(state: &AppState, headers: &HeaderMap) -> Result<Caller, ApiError> {
    let device = device_of(state, headers)?;
    let plex_token = headers
        .get("crucible-plex-token")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "no_plex_token", "The request carries no Plex token."))?
        .to_string();
    let hashed = hash_token(&plex_token);
    if state.config.policy == Policy::OnlyMe && state.owner_token_hash.as_deref() != Some(hashed.as_str()) {
        return Err(ApiError::new(StatusCode::FORBIDDEN, "owner_only", "The owner keeps Crucible Server to themselves."));
    }
    let fresh = {
        let accepted = state.accepted.lock().unwrap_or_else(PoisonError::into_inner);
        accepted.get(&hashed).is_some_and(|at| at.elapsed() < ACCEPTED_FOR)
    };
    if !fresh {
        if !state.plex.accepts(&plex_token).await? {
            return Err(ApiError::new(StatusCode::FORBIDDEN, "plex_refused", "Plex does not accept this account on this server."));
        }
        state.accepted.lock().unwrap_or_else(PoisonError::into_inner).insert(hashed.clone(), Instant::now());
    }
    Ok(Caller { device, plex_token, person: hashed[..16].to_string() })
}

async fn hello(State(state): State<Shared>) -> Json<Value> {
    Json(json!({
        "protocol": PROTOCOL,
        "name": state.config.name,
        "version": env!("CARGO_PKG_VERSION"),
        "fingerprint": state.fingerprint,
        "brain": state.writer.is_some(),
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairBegin {
    id: String,
    device_nonce: String,
}

async fn pair(State(state): State<Shared>, Json(body): Json<PairBegin>) -> Result<Json<Value>, ApiError> {
    if body.device_nonce.len() < 16 || body.device_nonce.len() > 128 {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_nonce", "The device nonce must be 16 to 128 characters."));
    }
    let (server_nonce, proof) = state.pairings.begin(&body.id, &body.device_nonce, &state.fingerprint).map_err(refused)?;
    Ok(Json(json!({"serverNonce": server_nonce, "proof": proof})))
}

#[derive(Deserialize)]
struct PairFinish {
    id: String,
    proof: String,
    name: String,
    platform: String,
}

async fn pair_confirm(State(state): State<Shared>, Json(body): Json<PairFinish>) -> Result<(StatusCode, Json<Value>), ApiError> {
    state.pairings.finish(&body.id, &body.proof, &state.fingerprint).map_err(refused)?;
    let token = new_device_token();
    let name: String = body.name.chars().filter(|c| !c.is_control()).take(60).collect();
    let platform: String = body.platform.chars().filter(|c| c.is_ascii_alphanumeric()).take(12).collect();
    let id =
        state.store.add_device(&name, &platform, &token).map_err(|error| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "database", error.to_string()))?;
    tracing::info!(device = %id, %platform, "paired a device");
    Ok((StatusCode::CREATED, Json(json!({"deviceId": id, "token": token, "name": state.config.name}))))
}

fn refused(_: Refused) -> ApiError {
    ApiError::new(StatusCode::FORBIDDEN, "pairing_refused", "That pairing code is wrong or has expired.")
        .hint("Run crucible-server pair on the Plex machine for a new one.")
}

async fn devices(State(state): State<Shared>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    device_of(&state, &headers)?;
    let devices = state.store.devices().map_err(|error| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "database", error.to_string()))?;
    Ok(Json(json!({"devices": devices})))
}

async fn remove_device(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<String>) -> Result<StatusCode, ApiError> {
    let me = device_of(&state, &headers)?;
    if me.id != id {
        caller(&state, &headers).await.and_then(|caller| {
            if state.owner_token_hash.as_deref() == Some(hash_token(&caller.plex_token).as_str()) {
                Ok(())
            } else {
                Err(ApiError::new(StatusCode::FORBIDDEN, "owner_only", "Only the owner can unpair another device."))
            }
        })?;
    }
    match state.store.remove_device(&id) {
        Ok(true) => Ok(StatusCode::NO_CONTENT),
        Ok(false) => Err(ApiError::new(StatusCode::NOT_FOUND, "not_found", "No such device.")),
        Err(error) => Err(ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "database", error.to_string())),
    }
}

async fn brain(State(state): State<Shared>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    device_of(&state, &headers)?;
    let Some(writer) = &state.writer else { return Ok(Json(json!({"model": null, "reachable": false}))) };
    let reachable = writer.brain.models().await.map(|models| models.contains(&writer.brain.model.name)).unwrap_or(false);
    Ok(Json(json!({"model": writer.brain.model.name, "reachable": reachable})))
}

async fn segments_for(State(state): State<Shared>, headers: HeaderMap, Path(rating_key): Path<String>) -> Result<Json<Value>, ApiError> {
    let caller = caller(&state, &headers).await?;
    let key = sanitize_key(&rating_key).ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "not_found", "Plex has no such item."))?;
    let item = state.plex.item(key, &caller.plex_token).await?;
    let found = segments::make(&item.plex_markers(), &item.plex_chapters(), item.duration.unwrap_or(0));
    Ok(Json(json!({"ratingKey": key, "segments": found})))
}

fn writer(state: &AppState) -> Result<Arc<Writer>, ApiError> {
    state.writer.clone().ok_or_else(|| {
        ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "no_model", "Crucible Server has no model set up.")
            .hint("Run crucible-server setup on the Plex machine and choose a model.")
    })
}

fn language(headers: &HeaderMap, body: Option<&str>) -> String {
    body.map(String::from)
        .or_else(|| {
            headers.get("accept-language").and_then(|value| value.to_str().ok()).and_then(|value| value.split(',').next()).map(|value| value.trim().to_string())
        })
        .unwrap_or_else(|| "en".into())
}

fn finished_keys(keys: Vec<String>) -> Result<Vec<String>, ApiError> {
    if keys.len() > 500 || keys.iter().any(|key| sanitize_key(key).is_none()) {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_finished", "finished must be at most 500 rating keys."));
    }
    Ok(keys)
}

#[derive(Deserialize)]
struct RecapRequest {
    finished: Vec<String>,
    language: Option<String>,
}

async fn start_recap(State(state): State<Shared>, headers: HeaderMap, Json(body): Json<RecapRequest>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let caller = caller(&state, &headers).await?;
    let writer = writer(&state)?;
    let finished = finished_keys(body.finished)?;
    if !state.jobs.has_room(&caller.person) {
        return Err(ApiError::new(StatusCode::TOO_MANY_REQUESTS, "busy", "A recap or answer for you is still being written."));
    }
    let language = language(&headers, body.language.as_deref());
    let token = caller.plex_token.clone();
    let id = state
        .jobs
        .start(&caller.person, async move { writer.recap(&finished, &token, &language).await.map(|recap| json!(recap)).map_err(|error| error.to_string()) });
    tracing::info!(device = %caller.device.id, job = %id, "recap started");
    Ok((StatusCode::ACCEPTED, Json(json!({"id": id}))))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuestionRequest {
    item: String,
    playhead_ms: u64,
    #[serde(default)]
    finished: Vec<String>,
    question: String,
    language: Option<String>,
}

async fn start_question(State(state): State<Shared>, headers: HeaderMap, Json(body): Json<QuestionRequest>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let caller = caller(&state, &headers).await?;
    let writer = writer(&state)?;
    let item = sanitize_key(&body.item).ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "not_found", "Plex has no such item."))?.to_string();
    let finished = finished_keys(body.finished)?;
    if body.question.trim().is_empty() || body.question.chars().count() > 500 {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_question", "Ask in 1 to 500 characters."));
    }
    if !state.jobs.has_room(&caller.person) {
        return Err(ApiError::new(StatusCode::TOO_MANY_REQUESTS, "busy", "A recap or answer for you is still being written."));
    }
    let language = language(&headers, body.language.as_deref());
    let token = caller.plex_token.clone();
    let id = state.jobs.start(&caller.person, async move {
        writer
            .answer(&item, body.playhead_ms, &finished, &body.question, &token, &language)
            .await
            .map(|answer| json!(answer))
            .map_err(|error| error.to_string())
    });
    Ok((StatusCode::ACCEPTED, Json(json!({"id": id}))))
}

#[derive(Deserialize)]
struct WaitQuery {
    wait: Option<u64>,
}

async fn collect(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<String>, Query(query): Query<WaitQuery>) -> Result<Json<Value>, ApiError> {
    let caller = caller(&state, &headers).await?;
    let wait = Duration::from_secs(query.wait.unwrap_or(0)).min(MAX_WAIT);
    match state.jobs.wait(&id, &caller.person, wait).await {
        None => Err(ApiError::new(StatusCode::NOT_FOUND, "not_found", "No such job.")),
        Some(JobState::Working) => Ok(Json(json!({"status": "working"}))),
        Some(JobState::Done(result)) => Ok(Json(json!({"status": "ready", "result": result}))),
        Some(JobState::Failed(message)) => Ok(Json(json!({"status": "failed", "message": message}))),
    }
}
