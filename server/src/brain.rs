//! The model, reached through any OpenAI-compatible endpoint: a model server on the owner's machines (llama-swap,
//! Ollama, LM Studio) or, when the owner chooses one and gives its key, a hosted service. Also the checks that keep
//! what it writes grounded: every name it uses must appear in what it was given, and every sentence must be
//! supported by the lines it cites.

use std::collections::BTreeSet;
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::{Duration, SystemTime};

use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::Semaphore;

use crate::config::Model;
use crate::net::{carries_a_key, model_place, ModelPlace};
use crate::paths::Paths;

#[derive(Debug, thiserror::Error)]
pub enum BrainError {
    #[error("the model at {0} did not answer: {1}")]
    Unreachable(String, String),
    #[error("the model answered {0}: {1}")]
    Status(u16, String),
    #[error("{0} did not accept the key: set one it accepts with crucible-server model --key-file")]
    KeyRefused(String),
    #[error("{0} wants payment before it answers: check the account the key belongs to")]
    Unpaid(String),
    #[error("{0} is turning requests away for now: too many at once, a model still loading, or a spent quota on the account the key belongs to")]
    Busy(String),
    #[error("the model's answer was not the JSON asked for")]
    Shape,
}

#[derive(Clone)]
pub struct Brain {
    pub model: Model,
    key: Option<String>,
    http: reqwest::Client,
    calls: Arc<Semaphore>,
    omitted: Arc<Mutex<Omitted>>,
}

#[derive(Deserialize)]
struct Completion {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: Message,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    #[serde(default)]
    content: Option<String>,
}

/// Tokens a reasoning model may spend thinking before its answer, on top of what the answer needs, at most a quarter
/// of the window.
const THINKING_ALLOWANCE: u32 = 4096;
/// Tokens kept for the instructions, the synopsis and the roster around the dialogue.
const PROMPT_RESERVE: u32 = 1800;
/// Seconds waited before asking again when the endpoint says it is busy and names no wait of its own.
const BUSY_WAITS: [u64; 3] = [2, 5, 10];
/// The longest wait an endpoint may ask for before a request is sent again.
const LONGEST_WAIT: u64 = 30;
/// How much of an endpoint's refusal is kept for the owner to read.
const REFUSAL_SHOWN: usize = 300;

/// A model the endpoint lists, with the context window it states when it states one (llama-swap's "· 256K").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listed {
    pub id: String,
    pub context: Option<u32>,
}

static CONTEXT_SIZE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(\d{1,4})\s*K\b").expect("context pattern"));

/// The window a model description names, such as "Gemma 4 26B · llama.cpp · UD-Q4_K_M · 8K".
pub fn context_in(description: &str) -> Option<u32> {
    CONTEXT_SIZE.captures_iter(description).last().and_then(|captures| captures[1].parse::<u32>().ok()).map(|thousands| thousands * 1024)
}

/// Two calls in flight per model host, so a recap never queues behind a whole season of background summaries.
const CALLS_IN_FLIGHT: usize = 2;

/// The request fields an endpoint has shown it will not take. A model server on the owner's machines accepts
/// llama.cpp's extra fields; a hosted service may answer 400 to a field it does not know or a setting its model does
/// not take, naming it. The request is then sent again without it, and the lesson is kept only once that request
/// succeeds, so a refusal that merely quotes the request changes nothing for later ones.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Omitted {
    template_switch: bool,
    max_tokens: bool,
    temperature: bool,
    response_format: bool,
}

impl Omitted {
    /// What to leave out from the first request: a hosted service is never sent llama.cpp's template switch.
    fn starting(place: &ModelPlace) -> Self {
        Omitted { template_switch: matches!(place, ModelPlace::Outside(_)), ..Omitted::default() }
    }

    /// What to leave out after a refusal: also every field it names that was still being sent, or nothing new when
    /// it names none of them.
    fn after(self, refusal: &str) -> Option<Self> {
        let refusal = refusal.to_lowercase();
        let named = |field: &str, already: bool| already || refusal.contains(field);
        let next = Omitted {
            template_switch: named("chat_template_kwargs", self.template_switch),
            max_tokens: named("max_tokens", self.max_tokens),
            temperature: named("temperature", self.temperature),
            response_format: named("response_format", self.response_format),
        };
        (next != self).then_some(next)
    }

    /// One chat turn asking for a JSON object, with only the fields this endpoint takes. An endpoint that refuses
    /// `max_tokens` is given the limit under its newer name.
    fn request(self, model: &str, system: &str, user: &str, tokens: u32) -> Value {
        let mut body = json!({
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        });
        body[if self.max_tokens { "max_completion_tokens" } else { "max_tokens" }] = json!(tokens);
        if !self.temperature {
            body["temperature"] = json!(0.2);
        }
        if !self.response_format {
            body["response_format"] = json!({"type": "json_object"});
        }
        if !self.template_switch {
            body["chat_template_kwargs"] = json!({"enable_thinking": false});
        }
        body
    }
}

/// The seconds an endpoint asks to be left alone for, from its `Retry-After` header: a number of seconds, or a
/// date to wait until.
fn retry_after(response: &reqwest::Response) -> Option<u64> {
    let asked = response.headers().get(reqwest::header::RETRY_AFTER)?.to_str().ok()?.trim();
    asked.parse().ok().or_else(|| {
        let until = httpdate::parse_http_date(asked).ok()?;
        Some(until.duration_since(SystemTime::now()).map_or(0, |wait| wait.as_secs()))
    })
}

impl Brain {
    /// A model that asks for no key.
    pub fn new(model: Model) -> Self {
        Brain::with_key(model, None)
    }

    /// A model with the key its endpoint asks for. An empty key is no key. Redirects are never followed, and a model
    /// on the owner's own networks is reached directly, never through a proxy the environment names, so what is sent
    /// goes to the address the owner chose and nowhere else.
    pub fn with_key(model: Model, key: Option<String>) -> Self {
        let place = model_place(&model.url);
        let builder =
            reqwest::Client::builder().timeout(Duration::from_secs(300)).connect_timeout(Duration::from_secs(5)).redirect(reqwest::redirect::Policy::none());
        let builder = if place == ModelPlace::Own { builder.no_proxy() } else { builder };
        let http = builder.build().expect("an HTTP client builds");
        let key = key.map(|key| key.trim().to_string()).filter(|key| !key.is_empty());
        let omitted = Arc::new(Mutex::new(Omitted::starting(&place)));
        Brain { model, key, http, calls: Arc::new(Semaphore::new(CALLS_IN_FLIGHT)), omitted }
    }

    /// The configured model with the key kept for its address, when one was.
    pub fn with_stored_key(model: Model, paths: &Paths) -> Self {
        let key = paths.model_key_for(&model.url);
        Brain::with_key(model, key)
    }

    /// Whether the model is on the owner's machines or at a host outside them.
    pub fn place(&self) -> ModelPlace {
        model_place(&self.model.url)
    }

    /// Whether a key is set and may travel to this endpoint.
    pub fn sends_key(&self) -> bool {
        self.key.is_some() && carries_a_key(&self.model.url)
    }

    /// The endpoint's host, for messages the owner reads.
    fn host(&self) -> String {
        reqwest::Url::parse(&self.model.url).ok().and_then(|url| url.host_str().map(str::to_string)).unwrap_or_else(|| self.model.url.clone())
    }

    fn endpoint(&self, route: &str) -> String {
        format!("{}/{route}", self.model.url.trim_end_matches('/'))
    }

    /// Adds the key to a request, never over plain HTTP to a host outside the owner's networks.
    fn authorized(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match &self.key {
            Some(key) if carries_a_key(&self.model.url) => request.bearer_auth(key),
            _ => request,
        }
    }

    /// An endpoint's own words with the key taken out, should it have echoed it plainly or as JSON writes it, cut to
    /// what is worth showing.
    fn shown(&self, refusal: &str) -> String {
        let text = match &self.key {
            Some(key) => {
                let as_json = serde_json::to_string(key).unwrap_or_default();
                refusal.replace(key.as_str(), "[key]").replace(as_json.trim_matches('"'), "[key]")
            }
            None => refusal.to_string(),
        };
        text.chars().take(REFUSAL_SHOWN).collect()
    }

    /// The models the endpoint lists, to check it answers and has the configured one.
    pub async fn models(&self) -> Result<Vec<String>, BrainError> {
        Ok(self.listed().await?.into_iter().map(|listed| listed.id).collect())
    }

    /// Whether the endpoint lists the configured model, under its own id or as the last part of a path-like id: a
    /// service that lists "models/name" answers to "name".
    pub async fn has_model(&self) -> Result<bool, BrainError> {
        let name = self.model.name.as_str();
        Ok(self.models().await?.iter().any(|id| id == name || id.rsplit('/').next() == Some(name)))
    }

    /// The models the endpoint lists, with their context windows when it states them.
    pub async fn listed(&self) -> Result<Vec<Listed>, BrainError> {
        let url = self.endpoint("models");
        let response = self
            .authorized(self.http.get(&url))
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .map_err(|error| BrainError::Unreachable(url.clone(), error.to_string()))?;
        let status = response.status();
        if !status.is_success() {
            let refusal = response.text().await.unwrap_or_default();
            return Err(self.refused(status.as_u16(), &refusal));
        }
        let body: Value = response.json().await.map_err(|_| BrainError::Shape)?;
        Ok(body["data"]
            .as_array()
            .map(|models| {
                models
                    .iter()
                    .filter_map(|model| {
                        let id = model["id"].as_str()?.to_string();
                        let context = model["description"].as_str().and_then(context_in).or_else(|| model["context_length"].as_u64().map(|n| n as u32));
                        Some(Listed { id, context })
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// The error a refusal stands for, in words that say what the owner can do about it. Some services answer a bad
    /// key with 400 and a sentence about the API key instead of 401.
    fn refused(&self, status: u16, refusal: &str) -> BrainError {
        match status {
            401 | 403 => BrainError::KeyRefused(self.host()),
            400 if refusal.to_lowercase().contains("api key") => BrainError::KeyRefused(self.host()),
            402 => BrainError::Unpaid(self.host()),
            429 | 503 => BrainError::Busy(self.host()),
            other => BrainError::Status(other, self.shown(refusal)),
        }
    }

    fn thinking_allowance(&self) -> u32 {
        THINKING_ALLOWANCE.min(self.model.context / 4)
    }

    /// How many characters of dialogue fit beside the prompt and the answer, at about three characters a token.
    pub fn dialogue_budget(&self, answer_tokens: u32) -> usize {
        let room = self.model.context.saturating_sub(PROMPT_RESERVE + answer_tokens + self.thinking_allowance());
        room as usize * 3
    }

    /// One chat turn at low temperature, answered as a JSON object. A refusal that names a field is answered by
    /// asking again without it, and a busy endpoint is given a few short waits before the turn fails; a wait never
    /// holds a place in the queue of calls.
    pub async fn ask_json(&self, system: &str, user: &str, max_tokens: u32) -> Result<Value, BrainError> {
        let url = self.endpoint("chat/completions");
        let tokens = max_tokens + self.thinking_allowance();
        let kept = *self.omitted.lock().unwrap_or_else(PoisonError::into_inner);
        let mut omitted = kept;
        let mut waits = BUSY_WAITS.iter();
        loop {
            let permit = self.calls.acquire().await.expect("the semaphore stays open");
            let body = omitted.request(&self.model.name, system, user, tokens);
            let response =
                self.authorized(self.http.post(&url)).json(&body).send().await.map_err(|error| BrainError::Unreachable(url.clone(), error.to_string()))?;
            let status = response.status().as_u16();
            if response.status().is_success() {
                let answer = Self::answer(response).await;
                if omitted != kept {
                    *self.omitted.lock().unwrap_or_else(PoisonError::into_inner) = omitted;
                }
                return answer;
            }
            let asked_wait = retry_after(&response);
            let refusal = response.text().await.unwrap_or_default();
            drop(permit);
            match status {
                400 | 422 => match omitted.after(&refusal) {
                    Some(without) => omitted = without,
                    None => return Err(self.refused(status, &refusal)),
                },
                429 | 503 => match waits.next() {
                    Some(wait) => tokio::time::sleep(Duration::from_secs(asked_wait.unwrap_or(*wait).min(LONGEST_WAIT))).await,
                    None => return Err(self.refused(status, &refusal)),
                },
                _ => return Err(self.refused(status, &refusal)),
            }
        }
    }

    /// The JSON object in a successful reply.
    async fn answer(response: reqwest::Response) -> Result<Value, BrainError> {
        let completion: Completion = response.json().await.map_err(|_| BrainError::Shape)?;
        let choice = completion.choices.into_iter().next().ok_or(BrainError::Shape)?;
        let content = choice.message.content.unwrap_or_default();
        first_json_object(&content).ok_or_else(|| {
            tracing::warn!(finish = ?choice.finish_reason, length = content.len(), start = %content.chars().take(160).collect::<String>(), "the model's reply held no JSON");
            BrainError::Shape
        })
    }
}

/// The first JSON object in a model's reply, which may wrap it in a code fence or a sentence.
pub fn first_json_object(text: &str) -> Option<Value> {
    let start = text.find('{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, character) in text[start..].char_indices() {
        if in_string {
            match character {
                '\\' if !escaped => escaped = true,
                '"' if !escaped => in_string = false,
                _ => escaped = false,
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return serde_json::from_str(&text[start..=start + offset]).ok();
                }
            }
            _ => {}
        }
    }
    None
}

static TRAILING_TIME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*[\[(]\d{1,2}:\d{2}(:\d{2})?[\])]\s*$").expect("time pattern"));

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{Lu}][\p{L}\p{M}'’\-]*").expect("word pattern"));
static SENTENCE_START: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(^|[.!?…]["”’)]?\s+)$"#).expect("sentence start pattern"));

/// Capitalised words that begin sentences in English and are not names.
const COMMON: &[&str] = &[
    "a",
    "after",
    "all",
    "also",
    "an",
    "and",
    "as",
    "at",
    "back",
    "before",
    "both",
    "but",
    "despite",
    "during",
    "each",
    "eventually",
    "even",
    "everyone",
    "finally",
    "for",
    "from",
    "he",
    "her",
    "his",
    "however",
    "i",
    "if",
    "in",
    "it",
    "its",
    "later",
    "meanwhile",
    "now",
    "on",
    "once",
    "one",
    "she",
    "so",
    "still",
    "the",
    "their",
    "then",
    "there",
    "they",
    "this",
    "though",
    "to",
    "together",
    "unable",
    "upon",
    "when",
    "while",
    "with",
    "without",
    "yet",
    "episode",
    "previously",
    "season",
    "s",
    "e",
];

/// The names in `text` that appear nowhere in `context`: a capitalised word in mid-sentence, or one that starts a
/// sentence and is not a common English word. Context words are matched ignoring case.
pub fn ungrounded_names(text: &str, context: &str) -> Vec<String> {
    let known: BTreeSet<String> = WORD.find_iter(context).map(|word| fold(word.as_str())).chain(context.split_whitespace().map(fold)).collect();
    let mut missing = BTreeSet::new();
    for word in WORD.find_iter(text) {
        let folded = fold(word.as_str());
        if folded.len() < 2 || COMMON.contains(&folded.as_str()) || known.contains(&folded) {
            continue;
        }
        let at_start = SENTENCE_START.is_match(&text[..word.start()]);
        if at_start && !text[word.end()..].trim_start().starts_with(|c: char| c.is_uppercase()) && is_plain_word(&folded) {
            continue;
        }
        missing.insert(word.as_str().trim_end_matches(['\'', '’', '-']).to_string());
    }
    missing.into_iter().collect()
}

fn fold(word: &str) -> String {
    word.trim_matches(|c: char| !c.is_alphanumeric()).trim_end_matches("'s").trim_end_matches("’s").to_lowercase()
}

/// A word that starts a sentence is taken as a name only when it does not look like an English word: names from
/// anime rosters (Goku, Vegeta, Beerus) end in vowels or use letters English words rarely start with.
fn is_plain_word(folded: &str) -> bool {
    folded.ends_with("ed") || folded.ends_with("ing") || folded.ends_with("ly") || folded.ends_with("s")
}

/// One sentence of a summary with the moment it rests on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cited {
    pub text: String,
    pub at_ms: Option<u64>,
}

/// The `{"sentences":[{"text","at"}]}` a summary prompt asks for.
pub fn cited_sentences(value: &Value) -> Vec<Cited> {
    value["sentences"]
        .as_array()
        .map(|sentences| {
            sentences
                .iter()
                .filter_map(|sentence| {
                    let text = TRAILING_TIME.replace(sentence["text"].as_str()?.trim(), "").trim().to_string();
                    (!text.is_empty()).then(|| Cited { text, at_ms: sentence["at"].as_str().and_then(parse_timestamp) })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// "12:34" or "1:02:03" as milliseconds.
pub fn parse_timestamp(text: &str) -> Option<u64> {
    let parts: Vec<u64> = text.trim().trim_matches(['[', ']']).split(':').map(|part| part.trim().parse().ok()).collect::<Option<_>>()?;
    let seconds = match parts.as_slice() {
        [minutes, seconds] => minutes * 60 + seconds,
        [hours, minutes, seconds] => (hours * 60 + minutes) * 60 + seconds,
        _ => return None,
    };
    Some(seconds * 1000)
}

#[cfg(test)]
pub(crate) mod testing {
    //! A stand-in model service on this machine, for tests: it keeps what it was sent and answers as told.

    use std::sync::{Arc, Mutex};

    use axum::extract::State;
    use axum::http::{HeaderMap, StatusCode};
    use axum::response::{IntoResponse, Response};
    use axum::routing::{get, post};
    use axum::{Json, Router};
    use serde_json::{json, Value};

    /// One request the service received: the bearer key it carried, if any, and its JSON body.
    #[derive(Clone, Debug)]
    pub struct Received {
        pub key: Option<String>,
        pub body: Value,
    }

    /// How the service answers a chat request, given everything it has received so far including this one.
    pub type Answering = Arc<dyn Fn(&[Received]) -> (u16, Vec<(&'static str, &'static str)>, Value) + Send + Sync>;

    #[derive(Clone)]
    pub struct Service {
        pub url: String,
        pub received: Arc<Mutex<Vec<Received>>>,
    }

    #[derive(Clone)]
    struct Told {
        received: Arc<Mutex<Vec<Received>>>,
        answering: Answering,
        listed: Value,
    }

    /// The reply of a model that did as asked.
    pub fn fine() -> Value {
        json!({"choices": [{"message": {"content": "{\"ok\": true}"}, "finish_reason": "stop"}]})
    }

    fn bearer(headers: &HeaderMap) -> Option<String> {
        headers.get("authorization")?.to_str().ok()?.strip_prefix("Bearer ").map(str::to_string)
    }

    async fn chat(State(told): State<Told>, headers: HeaderMap, Json(body): Json<Value>) -> Response {
        let (status, extra, reply) = {
            let mut received = told.received.lock().unwrap();
            received.push(Received { key: bearer(&headers), body });
            (told.answering)(&received)
        };
        let mut response = (StatusCode::from_u16(status).unwrap(), Json(reply)).into_response();
        for (name, value) in extra {
            response.headers_mut().insert(name, value.parse().unwrap());
        }
        response
    }

    async fn models(State(told): State<Told>, headers: HeaderMap) -> Response {
        told.received.lock().unwrap().push(Received { key: bearer(&headers), body: Value::Null });
        Json(told.listed.clone()).into_response()
    }

    /// Starts a service that lists `listing` as its models and answers chat requests through `answering`.
    async fn start_with(listing: Value, answering: Answering) -> Service {
        let received = Arc::new(Mutex::new(Vec::new()));
        let told = Told { received: received.clone(), answering, listed: listing };
        let router = Router::new().route("/v1/chat/completions", post(chat)).route("/v1/models", get(models)).with_state(told);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        Service { url, received }
    }

    /// Starts a service listing `listed` model ids, each with a 128K window, that answers through `answering`.
    pub async fn start(listed: &[&str], answering: Answering) -> Service {
        let listing = json!({"data": listed.iter().map(|id| json!({"id": id, "context_length": 131072})).collect::<Vec<_>>()});
        start_with(listing, answering).await
    }

    /// A service that answers every chat request, whoever asks.
    pub async fn open(listed: &[&str]) -> Service {
        start(listed, Arc::new(|_| (200, Vec::new(), fine()))).await
    }

    /// A service that answers every chat request and lists its models exactly as `listing` says.
    pub async fn start_listing(listing: Value) -> Service {
        start_with(listing, Arc::new(|_| (200, Vec::new(), fine()))).await
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{fine, start, Received};
    use super::*;

    fn model(url: &str, name: &str) -> Model {
        Model { url: url.into(), name: name.into(), context: 32_768 }
    }

    fn refusal(message: &str) -> Value {
        json!({"error": {"message": message, "type": "invalid_request_error"}})
    }

    #[tokio::test]
    async fn a_service_that_wants_a_key_gets_it_and_a_wrong_one_is_named_plainly() {
        let service = start(
            &["writer"],
            Arc::new(|received: &[Received]| match received.last().and_then(|request| request.key.as_deref()) {
                Some("sk-right") => (200, Vec::new(), fine()),
                _ => (401, Vec::new(), json!({"error": {"message": "Incorrect API key provided"}})),
            }),
        )
        .await;
        let with_key = Brain::with_key(model(&service.url, "writer"), Some(" sk-right\n".into()));
        assert!(with_key.ask_json("s", "u", 20).await.is_ok());
        let wrong = Brain::with_key(model(&service.url, "writer"), Some("sk-wrong".into()));
        assert!(matches!(wrong.ask_json("s", "u", 20).await, Err(BrainError::KeyRefused(host)) if host == "127.0.0.1"));
        assert!(matches!(wrong.refused(400, "{\"error\": {\"message\": \"Please pass a valid API key\"}}"), BrainError::KeyRefused(_)));
        assert!(matches!(wrong.refused(400, "the prompt is too long"), BrainError::Status(400, _)));
        assert!(matches!(Brain::new(model(&service.url, "writer")).ask_json("s", "u", 20).await, Err(BrainError::KeyRefused(_))));
    }

    #[tokio::test]
    async fn learns_what_a_strict_service_refuses_and_does_not_send_it_again() {
        let service = start(
            &["writer"],
            Arc::new(|received: &[Received]| {
                let body = &received.last().unwrap().body;
                if body.get("chat_template_kwargs").is_some() {
                    (400, Vec::new(), refusal("Unrecognized request argument supplied: chat_template_kwargs"))
                } else if body.get("max_tokens").is_some() {
                    (400, Vec::new(), refusal("Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."))
                } else if body.get("temperature").is_some() {
                    (400, Vec::new(), refusal("Unsupported value: 'temperature' does not support 0.2 with this model."))
                } else {
                    (200, Vec::new(), fine())
                }
            }),
        )
        .await;
        let brain = Brain::new(model(&service.url, "writer"));
        assert!(brain.ask_json("s", "u", 20).await.is_ok());
        let sent = service.received.lock().unwrap().clone();
        assert_eq!(sent.len(), 4);
        assert!(sent[0].body.get("chat_template_kwargs").is_some() && sent[0].body.get("max_tokens").is_some());
        let last = &sent[3].body;
        assert_eq!(last["max_completion_tokens"], json!(20 + 4096));
        assert!(last.get("max_tokens").is_none() && last.get("temperature").is_none() && last.get("chat_template_kwargs").is_none());
        assert_eq!(last["response_format"], json!({"type": "json_object"}));
        assert!(brain.ask_json("s", "u", 20).await.is_ok());
        assert_eq!(service.received.lock().unwrap().len(), 5);
    }

    #[tokio::test]
    async fn a_refusal_that_only_quotes_the_request_changes_nothing_for_later_ones() {
        let service = start(
            &["writer"],
            Arc::new(|received: &[Received]| match received.len() {
                1 | 2 => (400, Vec::new(), refusal("could not parse {\"chat_template_kwargs\": {}, \"temperature\": 0.2, \"max_tokens\": 20}")),
                _ => (200, Vec::new(), fine()),
            }),
        )
        .await;
        let brain = Brain::new(model(&service.url, "writer"));
        assert!(matches!(brain.ask_json("s", "u", 20).await, Err(BrainError::Status(400, _))));
        assert!(brain.ask_json("s", "u", 20).await.is_ok());
        let sent = service.received.lock().unwrap().clone();
        assert_eq!(sent.len(), 3);
        let later = &sent[2].body;
        assert!(later.get("chat_template_kwargs").is_some() && later.get("temperature").is_some() && later.get("max_tokens").is_some());
    }

    #[tokio::test]
    async fn a_redirect_is_not_followed_to_wherever_it_points() {
        let elsewhere = testing::open(&["writer"]).await;
        let target: &'static str = Box::leak(format!("{}/chat/completions", elsewhere.url).into_boxed_str());
        let pointing = start(&["writer"], Arc::new(move |_| (307, vec![("location", target)], json!({})))).await;
        let brain = Brain::new(model(&pointing.url, "writer"));
        assert!(matches!(brain.ask_json("s", "u", 20).await, Err(BrainError::Status(307, _))));
        assert!(elsewhere.received.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_refusal_that_teaches_nothing_is_reported_without_the_key() {
        let service = start(&["writer"], Arc::new(|_| (400, Vec::new(), refusal("The prompt is too long for sk-secret-key to take.")))).await;
        let brain = Brain::with_key(model(&service.url, "writer"), Some("sk-secret-key".into()));
        match brain.ask_json("s", "u", 20).await {
            Err(BrainError::Status(400, shown)) => assert!(shown.contains("too long") && !shown.contains("sk-secret-key") && shown.contains("[key]")),
            other => panic!("expected the refusal, got {other:?}"),
        }
        assert_eq!(service.received.lock().unwrap().len(), 1);
        let quoted = Brain::with_key(model(&service.url, "writer"), Some("sk-a\"b\\c".into()));
        assert_eq!(quoted.shown(r#"{"error":"bad key sk-a\"b\\c here"}"#), r#"{"error":"bad key [key] here"}"#);
    }

    #[tokio::test]
    async fn refused_fields_do_not_use_up_the_waits_for_a_busy_service() {
        let service = start(
            &["writer"],
            Arc::new(|received: &[Received]| {
                let body = &received.last().unwrap().body;
                if body.get("temperature").is_some() {
                    (400, Vec::new(), refusal("'temperature' is not supported"))
                } else if body.get("max_tokens").is_some() {
                    (400, Vec::new(), refusal("use max_completion_tokens, not max_tokens"))
                } else if body.get("response_format").is_some() {
                    (400, Vec::new(), refusal("response_format is not supported"))
                } else if received.len() < 4 + BUSY_WAITS.len() {
                    (429, vec![("retry-after", "0")], json!({}))
                } else {
                    (200, Vec::new(), fine())
                }
            }),
        )
        .await;
        assert!(Brain::new(model(&service.url, "writer")).ask_json("s", "u", 20).await.is_ok());
        assert_eq!(service.received.lock().unwrap().len(), 4 + BUSY_WAITS.len());
    }

    #[tokio::test]
    async fn waits_out_a_busy_service_and_gives_up_plainly_when_it_stays_busy() {
        let recovering = start(
            &["writer"],
            Arc::new(|received: &[Received]| if received.len() < 3 { (429, vec![("retry-after", "0")], json!({})) } else { (200, Vec::new(), fine()) }),
        )
        .await;
        assert!(Brain::new(model(&recovering.url, "writer")).ask_json("s", "u", 20).await.is_ok());
        assert_eq!(recovering.received.lock().unwrap().len(), 3);

        let dated = start(
            &["writer"],
            Arc::new(
                |received: &[Received]| {
                    if received.len() < 2 {
                        (503, vec![("retry-after", "Fri, 13 Nov 2020 12:00:30 GMT")], json!({}))
                    } else {
                        (200, Vec::new(), fine())
                    }
                },
            ),
        )
        .await;
        assert!(Brain::new(model(&dated.url, "writer")).ask_json("s", "u", 20).await.is_ok());

        let swamped = start(&["writer"], Arc::new(|_| (429, vec![("retry-after", "0")], json!({})))).await;
        assert!(matches!(Brain::new(model(&swamped.url, "writer")).ask_json("s", "u", 20).await, Err(BrainError::Busy(_))));
        assert_eq!(swamped.received.lock().unwrap().len(), 1 + BUSY_WAITS.len());

        let unpaid = start(&["writer"], Arc::new(|_| (402, Vec::new(), json!({"error": {"message": "Insufficient credits"}})))).await;
        assert!(matches!(Brain::new(model(&unpaid.url, "writer")).ask_json("s", "u", 20).await, Err(BrainError::Unpaid(_))));
    }

    #[tokio::test]
    async fn finds_its_model_under_a_path_like_id_and_lists_with_the_key() {
        let service = testing::open(&["models/gemini-flash", "vendor/other"]).await;
        let brain = Brain::with_key(model(&service.url, "gemini-flash"), Some("sk-right".into()));
        assert!(brain.has_model().await.unwrap());
        assert_eq!(service.received.lock().unwrap()[0].key.as_deref(), Some("sk-right"));
        assert!(Brain::new(model(&service.url, "vendor/other")).has_model().await.unwrap());
        assert!(!Brain::new(model(&service.url, "missing")).has_model().await.unwrap());
        assert_eq!(brain.listed().await.unwrap()[0], Listed { id: "models/gemini-flash".into(), context: Some(131_072) });
    }

    #[test]
    fn a_service_outside_is_never_sent_the_template_switch_or_a_key_in_the_clear() {
        let request = |place: ModelPlace| Omitted::starting(&place).request("m", "s", "u", 100);
        assert!(request(ModelPlace::Own).get("chat_template_kwargs").is_some());
        let outside = request(ModelPlace::Outside("openrouter.ai".into()));
        assert!(outside.get("chat_template_kwargs").is_none());
        assert_eq!(outside["max_tokens"], json!(100));

        let key = Some("sk-right".to_string());
        assert!(Brain::with_key(model("https://openrouter.ai/api/v1", "m"), key.clone()).sends_key());
        assert!(Brain::with_key(model("http://127.0.0.1:8081/v1", "m"), key.clone()).sends_key());
        assert!(!Brain::with_key(model("http://openrouter.ai/api/v1", "m"), key).sends_key());
        assert!(!Brain::with_key(model("https://openrouter.ai/api/v1", "m"), Some("  ".into())).sends_key());
        assert_eq!(Brain::new(model("https://openrouter.ai/api/v1", "m")).place(), ModelPlace::Outside("openrouter.ai".into()));
    }

    #[test]
    fn drops_a_timestamp_the_model_also_wrote_into_the_sentence() {
        let value = serde_json::json!({"sentences": [{"text": "Goku trains. [8:53]", "at": "8:53"}, {"text": "Beerus naps (12:01)"}]});
        assert_eq!(cited_sentences(&value).iter().map(|s| s.text.as_str()).collect::<Vec<_>>(), vec!["Goku trains.", "Beerus naps"]);
    }

    #[test]
    fn finds_the_json_in_a_fenced_reply() {
        let value = first_json_object("Sure!\n```json\n{\"sentences\":[{\"text\":\"Goku {trains}.\",\"at\":\"3:01\"}]}\n```").unwrap();
        let sentences = cited_sentences(&value);
        assert_eq!(sentences, vec![Cited { text: "Goku {trains}.".into(), at_ms: Some(181_000) }]);
        assert!(first_json_object("no json here").is_none());
    }

    #[test]
    fn flags_a_name_the_context_never_mentions() {
        let context = "Goku and Vegeta train on Beerus's planet. Whis watches.";
        assert!(ungrounded_names("Goku trains with Vegeta while Whis watches. Beerus naps.", context).is_empty());
        assert_eq!(ungrounded_names("Goku trains while Mr. Satan cheers.", context), vec!["Mr", "Satan"]);
        assert_eq!(ungrounded_names("Later, Goku meets Hit.", context), vec!["Hit"]);
        assert!(ungrounded_names("Determined, Goku trains harder. Afterwards he rests.", context).is_empty());
    }

    #[test]
    fn reads_the_context_window_from_a_description() {
        assert_eq!(context_in("Gemma 4 26B · llama.cpp · UD-Q4_K_M · 8K"), Some(8192));
        assert_eq!(context_in("Groot 19B · vLLM · NVFP4 · MTP · 256K"), Some(262_144));
        assert_eq!(context_in("no size"), None);
    }

    #[test]
    fn reads_timestamps() {
        assert_eq!(parse_timestamp("[12:34]"), Some(754_000));
        assert_eq!(parse_timestamp("1:02:03"), Some(3_723_000));
        assert_eq!(parse_timestamp("soon"), None);
    }
}
