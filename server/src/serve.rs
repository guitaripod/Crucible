//! `crucible-server serve`: HTTPS on every interface at the configured port, answering only this machine, the
//! home network and the tailnet.

use std::net::SocketAddr;
use std::sync::Arc;

use axum_server::tls_rustls::RustlsConfig;

use crate::api::{router, AppState};
use crate::brain::Brain;
use crate::config::Config;
use crate::home::Home;
use crate::pairing::Pairings;
use crate::paths::Paths;
use crate::plex::Plex;
use crate::plextv::PlexTv;
use crate::recap::Writer;
use crate::store::Store;
use crate::{setup, tls};

pub async fn run(paths: &Paths) -> Result<(), String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = Arc::new(Config::load(&paths.config()).map_err(|error| format!("{error}. Run crucible-server setup first."))?);
    let owner_token = std::fs::read_to_string(paths.plex_token()).ok().map(|token| token.trim().to_string());
    let store = Arc::new(Store::open(&paths.database()).map_err(|error| error.to_string())?);
    let identity = tls::load_or_create(paths, &config.name).map_err(|error| error.to_string())?;
    let client = setup::client_id(paths).map_err(|error| error.to_string())?;
    let plex = Plex::new(&config.plex_url, &client);
    let writer =
        config.model.clone().map(|model| Arc::new(Writer { plex: plex.clone(), brain: Brain::new(model), store: store.clone(), config: config.clone() }));
    let state = Arc::new(AppState::new(
        config.clone(),
        store.clone(),
        Arc::new(Pairings::backed_by(store)),
        identity.fingerprint.clone(),
        plex,
        writer,
        Home::new(PlexTv::new(&client), owner_token, config.machine_identifier.clone()),
    ));
    let tls = RustlsConfig::from_pem_file(paths.certificate(), paths.private_key()).await.map_err(|error| error.to_string())?;
    let address = SocketAddr::from(([0, 0, 0, 0], config.port));
    let handle = axum_server::Handle::new();
    let stopping = handle.clone();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        stopping.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
    });
    tracing::info!(%address, fingerprint = %identity.fingerprint, model = config.model.as_ref().map_or("none", |m| m.name.as_str()), "Crucible Server listening");
    axum_server::bind_rustls(address, tls)
        .handle(handle)
        .serve(router(state).into_make_service_with_connect_info::<SocketAddr>())
        .await
        .map_err(|error| format!("Could not listen on port {}: {error}", config.port))
}
