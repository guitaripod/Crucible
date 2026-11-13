//! `crucible-server doctor`: every check setup made, again, with what to do about each failure.

use std::time::Duration;

use crate::brain::Brain;
use crate::config::{Config, Policy};
use crate::home::Home;
use crate::net::{carries_a_key, ModelPlace};
use crate::paths::Paths;
use crate::plex::Plex;
use crate::plextv::PlexTv;
use crate::store::Store;
use crate::{setup, tls};

/// One check's outcome.
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

fn check(name: &'static str, ok: bool, detail: impl Into<String>) -> Check {
    Check { name, ok, detail: detail.into() }
}

/// Who the owner's policy lets in; for My Plex Home, how many people plex.tv lists in the Home with access.
async fn who_may_use_it(paths: &Paths, config: &Config, client: &str) -> Check {
    match config.policy {
        Policy::OnlyMe => check("Who may use it", true, "only you"),
        Policy::Everyone => check("Who may use it", true, "everyone this Plex server is shared with"),
        Policy::MyPlexHome => {
            let owner = std::fs::read_to_string(paths.plex_token()).ok().map(|token| token.trim().to_string());
            match Home::new(PlexTv::new(client), owner, config.machine_identifier.clone()).count().await {
                Ok(count) => check("Who may use it", true, format!("you and {count} more in your Plex Home with access to this server")),
                Err(error) => check("Who may use it", false, format!("{error}: only you until plex.tv lists your Plex Home")),
            }
        }
    }
}

/// Whether the model is there, where it is, and whether its key can reach it.
async fn model_check(paths: &Paths, config: &Config) -> Check {
    let model = match config.usable_model() {
        Ok(Some(model)) => model,
        Ok(None) => return check("Model", false, "none set: recaps and answers are off (crucible-server model --url)"),
        Err(unused) => return check("Model", false, format!("not used: {unused}")),
    };
    let brain = Brain::with_stored_key(model.clone(), paths);
    let place = match brain.place() {
        ModelPlace::Own => String::new(),
        ModelPlace::Outside(host) => format!(" (outside your network, at {host}{})", if brain.sends_key() { ", with your key" } else { "" }),
    };
    if paths.model_key_for(&model.url).is_some() && !carries_a_key(&model.url) {
        return check(
            "Model",
            false,
            format!("the key is not sent to {} over plain HTTP: set its https:// address with crucible-server model --url", model.url),
        );
    }
    match tokio::time::timeout(Duration::from_secs(15), brain.has_model()).await {
        Ok(Ok(true)) => check("Model", true, format!("{} is offered at {}{place}", model.name, model.url)),
        Ok(Ok(false)) => check("Model", false, format!("{} no longer lists {}", model.url, model.name)),
        Ok(Err(error)) => check("Model", false, error.to_string()),
        Err(_) => check("Model", false, format!("{} did not answer in 15 seconds", model.url)),
    }
}

pub async fn run(paths: &Paths) -> Vec<Check> {
    let mut checks = Vec::new();
    let config = match Config::load(&paths.config()) {
        Ok(config) => config,
        Err(error) => {
            checks.push(check("Setup", false, format!("{error}: run crucible-server setup")));
            return checks;
        }
    };
    checks.push(check("Setup", true, format!("{} at {}", config.name, paths.root.display())));
    let client = setup::client_id(paths).unwrap_or_default();
    let plex = Plex::new(&config.plex_url, &client);
    match plex.identity().await {
        Ok((machine, version)) if machine == config.machine_identifier => {
            checks.push(check("Plex", true, format!("Plex Media Server {version} at {}", config.plex_url)))
        }
        Ok((machine, _)) => checks.push(check("Plex", false, format!("{} is a different Plex server ({machine}); run setup again", config.plex_url))),
        Err(error) => checks.push(check("Plex", false, error.to_string())),
    }
    match plex.refuses_strangers().await {
        Ok(true) => checks.push(check("Plex refuses strangers", true, "no access without a token")),
        Ok(false) => checks.push(check("Plex refuses strangers", false, "Plex allows this network without auth: turn it off in Settings, Network")),
        Err(error) => checks.push(check("Plex refuses strangers", false, error.to_string())),
    }
    match std::fs::read_to_string(paths.plex_token()) {
        Ok(token) => match plex.accepts(token.trim()).await {
            Ok(true) => checks.push(check("Owner sign-in", true, format!("signed in as {}", config.owner))),
            Ok(false) => checks.push(check("Owner sign-in", false, "Plex no longer accepts the owner's token: run setup again")),
            Err(error) => checks.push(check("Owner sign-in", false, error.to_string())),
        },
        Err(_) => checks.push(check("Owner sign-in", false, "no owner token: run setup")),
    }
    checks.push(who_may_use_it(paths, &config, &client).await);
    let ffmpeg = tokio::process::Command::new("ffmpeg").arg("-version").output().await;
    match ffmpeg {
        Ok(output) if output.status.success() => {
            checks.push(check("ffmpeg", true, String::from_utf8_lossy(&output.stdout).lines().next().unwrap_or("").to_string()))
        }
        _ => checks.push(check("ffmpeg", false, "not found: install ffmpeg so recaps can read subtitles")),
    }
    checks.push(model_check(paths, &config).await);
    match tls::load_or_create(paths, &config.name) {
        Ok(identity) => checks.push(check("Certificate", true, format!("fingerprint {}…", &identity.fingerprint[..16]))),
        Err(error) => checks.push(check("Certificate", false, error.to_string())),
    }
    match tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(("127.0.0.1", config.port))).await {
        Ok(Ok(_)) => checks.push(check("Listening", true, format!("port {}", config.port))),
        _ => checks.push(check("Listening", false, format!("nothing on port {}: start the service or run crucible-server serve", config.port))),
    }
    match Store::open(&paths.database()).and_then(|store| store.devices()) {
        Ok(devices) => checks.push(check("Devices", true, format!("{} paired", devices.len()))),
        Err(error) => checks.push(check("Devices", false, error.to_string())),
    }
    checks
}
