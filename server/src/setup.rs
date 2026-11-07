//! `crucible-server setup`: find Plex here, prove it refuses strangers, sign the owner in, pick a model, make the
//! certificate, keep the server running, and show the first pairing code.

use std::path::PathBuf;
use std::time::Duration;

use crate::brain::{Brain, Listed};
use crate::config::{Config, Model, Policy, DEFAULT_CONTEXT};
use crate::net::{host_port, reachable_addresses};
use crate::pairing::Pairings;
use crate::paths::{write_private, Paths};
use crate::plex::Plex;
use crate::plextv::{owned_server, PlexTv};
use crate::store::Store;
use crate::terminal::{ask, confirm, qr};
use crate::{service, tls};

/// What `setup` may be told instead of asking.
#[derive(Clone, Debug, Default)]
pub struct Options {
    pub plex_url: Option<String>,
    pub token_file: Option<PathBuf>,
    pub model_url: Option<String>,
    pub model: Option<String>,
    pub policy: Option<Policy>,
    pub assume_yes: bool,
    pub no_service: bool,
}

/// Model servers looked for on this machine, in order.
const MODEL_HOSTS: &[(&str, &str)] =
    &[("llama-swap", "http://127.0.0.1:8081/v1"), ("Ollama", "http://127.0.0.1:11434/v1"), ("LM Studio", "http://127.0.0.1:1234/v1")];
/// Models preferred for summaries when several are offered, best first.
/// A window that holds a whole episode's dialogue with room to think.
const ROOMY: u32 = 32 * 1024;
const PREFERRED: &[&str] = &[
    "groot-19b",
    "gemma4-26b",
    "gemma-4-26b",
    "gemma4:26b",
    "qwen3-30b",
    "qwen3:30b",
    "gemma4-12b",
    "gemma4:12b",
    "gemma3-27b",
    "gemma3:27b",
    "qwen3-14b",
    "qwen3:14b",
    "gemma3-12b",
    "gemma3:12b",
];

/// A stable id for this install, which Plex and plex.tv see as the client.
pub fn client_id(paths: &Paths) -> std::io::Result<String> {
    let file = paths.root.join("client-id");
    if let Ok(id) = std::fs::read_to_string(&file) {
        return Ok(id.trim().to_string());
    }
    let id = uuid::Uuid::new_v4().to_string();
    write_private(&file, id.as_bytes())?;
    Ok(id)
}

pub fn machine_name() -> String {
    std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "Plex server".into())
}

/// The models worth trying, best first: the one asked for alone, else the preferred models with a window for a whole
/// episode's dialogue, then the preferred ones with a smaller window, then whatever else is listed.
fn candidates(models: &[Listed], wanted: Option<&str>) -> Vec<Listed> {
    if let Some(wanted) = wanted {
        return models.iter().filter(|model| model.id == wanted).cloned().collect();
    }
    let rank = |model: &Listed| {
        let preference = PREFERRED.iter().position(|name| model.id.to_lowercase().contains(name)).unwrap_or(PREFERRED.len());
        let roomy = model.context.unwrap_or(DEFAULT_CONTEXT) >= ROOMY;
        (preference == PREFERRED.len(), !roomy, preference)
    };
    let mut ordered = models.to_vec();
    ordered.sort_by_key(rank);
    ordered
}

/// Whether the model answers a tiny request, giving a model server time to load it.
async fn answers(url: &str, model: &Listed) -> bool {
    let brain = Brain::new(Model { url: url.into(), name: model.id.clone(), context: model.context.unwrap_or(DEFAULT_CONTEXT) });
    let check = brain.ask_json("Reply with JSON only.", "Reply with {\"ok\": true}", 20);
    matches!(tokio::time::timeout(Duration::from_secs(180), check).await, Ok(Ok(_)))
}

pub async fn run(paths: &Paths, options: Options) -> Result<(), String> {
    paths.ensure().map_err(|error| format!("Could not create {}: {error}", paths.root.display()))?;
    println!("Crucible Server {}\n", env!("CARGO_PKG_VERSION"));
    let client = client_id(paths).map_err(|error| error.to_string())?;
    let mut config = Config::load(&paths.config()).unwrap_or_else(|_| Config::new(&machine_name()));
    if let Some(url) = options.plex_url.clone() {
        config.plex_url = url;
    }

    let plex = Plex::new(&config.plex_url, &client);
    let (machine, version) =
        plex.identity().await.map_err(|error| format!("{error}\nIs Plex Media Server running on this computer? Point to it with --plex-url."))?;
    if !plex.refuses_strangers().await.map_err(|error| error.to_string())? {
        return Err("Plex lets this network in without signing in, so anyone here could read your library through Crucible Server.\n\
Turn it off in Plex: Settings, Network, \"List of IP addresses and networks that are allowed without auth\", then run setup again."
            .into());
    }

    let token = match &options.token_file {
        Some(file) => std::fs::read_to_string(file).map_err(|error| format!("Could not read {}: {error}", file.display()))?.trim().to_string(),
        None => sign_in(&client).await?,
    };
    let plextv = PlexTv::new(&client);
    let account = plextv.account(&token).await.map_err(|error| error.to_string())?;
    let resources = plextv.resources(&token).await.map_err(|error| error.to_string())?;
    let Some(server) = owned_server(&resources, &machine) else {
        return Err(format!("Signed in as {}, but the Plex server on this computer belongs to another account.", account.username));
    };
    let server_token = server.access_token.clone().unwrap_or_else(|| token.clone());
    write_private(&paths.plex_token(), server_token.as_bytes()).map_err(|error| error.to_string())?;
    config.machine_identifier = machine.clone();
    config.owner = account.username.clone();
    config.name = if server.name.is_empty() { config.name } else { server.name.clone() };
    println!("Signed in as {}. Found \"{}\" (Plex Media Server {version}) on this computer.", account.username, config.name);

    config.policy = match options.policy {
        Some(policy) => policy,
        None if options.assume_yes => config.policy,
        None => match ask("Who may use Crucible Server? 1 only me, 2 my Plex Home, 3 everyone the server is shared with", "2").as_str() {
            "1" => Policy::OnlyMe,
            "3" => Policy::Everyone,
            _ => Policy::MyPlexHome,
        },
    };

    config.model = pick_model(&options).await;
    match &config.model {
        Some(model) => println!("Model: {} at {}.", model.name, model.url),
        None => println!("Model: none yet. Skips work now; recaps and answers start once a model is set (crucible-server setup --model-url)."),
    }

    config.save(&paths.config()).map_err(|error| error.to_string())?;
    let identity = tls::load_or_create(paths, &config.name).map_err(|error| error.to_string())?;

    if !options.no_service && (options.assume_yes || confirm("Keep Crucible Server running after you log out?", true)) {
        match service::install(&paths.root, &paths.log()) {
            Ok(at) => println!("Running as a service ({}).", at.display()),
            Err(error) => println!("Could not install the service ({error}); run `crucible-server serve` yourself."),
        }
    }

    let store = Store::open(&paths.database()).map_err(|error| error.to_string())?;
    show_pairing(&config, &identity.fingerprint, &store)
}

async fn sign_in(client: &str) -> Result<String, String> {
    let plextv = PlexTv::new(client);
    let pin = plextv.create_pin().await.map_err(|error| error.to_string())?;
    println!("Sign in to Plex: open plex.tv/link and enter {}", pin.code);
    for _ in 0..300 {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if let Ok(checked) = plextv.check_pin(pin.id).await {
            if let Some(token) = checked.auth_token.filter(|token| !token.is_empty()) {
                return Ok(token);
            }
        }
    }
    Err("The code expired before it was entered. Run setup again.".into())
}

async fn pick_model(options: &Options) -> Option<Model> {
    let hosts: Vec<(String, String)> = match &options.model_url {
        Some(url) => vec![("the model server".into(), url.clone())],
        None => MODEL_HOSTS.iter().map(|(name, url)| (name.to_string(), url.to_string())).collect(),
    };
    for (name, url) in hosts {
        let probe = Brain::new(Model { url: url.clone(), name: String::new(), context: DEFAULT_CONTEXT });
        let Ok(models) = probe.listed().await else { continue };
        println!("Found {name} at {url} with {} models.", models.len());
        for candidate in candidates(&models, options.model.as_deref()).into_iter().take(4) {
            if !(options.assume_yes || confirm(&format!("Use {} for recaps and answers?", candidate.id), true)) {
                continue;
            }
            println!("Checking {} (a model can take a few minutes to load)...", candidate.id);
            if answers(&url, &candidate).await {
                return Some(Model { url, name: candidate.id, context: candidate.context.unwrap_or(DEFAULT_CONTEXT) });
            }
            println!("{} did not answer; trying the next one.", candidate.id);
        }
    }
    None
}

/// Prints the QR code and the typed code for pairing a device.
pub fn show_pairing(config: &Config, fingerprint: &str, store: &Store) -> Result<(), String> {
    let shown = Pairings::open_for_server(store).map_err(|error| error.to_string())?;
    let hosts: Vec<String> = reachable_addresses().into_iter().map(|ip| host_port(ip, config.port)).collect();
    if hosts.is_empty() {
        return Err("This computer has no address on a home network or tailnet for a device to reach.".into());
    }
    println!("\nScan this with the Camera on your iPhone or iPad, or in Crucible (Settings, Crucible Server, Pair):\n");
    println!("{}", qr(&shown.link(&config.name, &hosts, fingerprint)));
    println!("Or type: {}   (works once, for 10 minutes; new one: crucible-server pair)", shown.code);
    println!("Address: {}", hosts.join(", "));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tries_good_summary_models_with_room_for_an_episode_first() {
        let listed = |id: &str, context: Option<u32>| Listed { id: id.into(), context };
        let models = vec![listed("flint", Some(262_144)), listed("gemma4-26b-a4b-gguf", Some(8_192)), listed("qwen3-30b-a3b", Some(131_072))];
        let order: Vec<String> = candidates(&models, None).into_iter().map(|m| m.id).collect();
        assert_eq!(order, vec!["qwen3-30b-a3b", "gemma4-26b-a4b-gguf", "flint"]);
        assert_eq!(candidates(&models, Some("flint")).len(), 1);
        assert!(candidates(&models, Some("missing")).is_empty());
    }
}
