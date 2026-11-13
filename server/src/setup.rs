//! `crucible-server setup`: find Plex here, prove it refuses strangers, sign the owner in, pick a model, make the
//! certificate, keep the server running, and show the first pairing code.

use std::path::PathBuf;
use std::time::Duration;

use crate::brain::{Brain, Listed};
use crate::config::{Config, Model, Policy, DEFAULT_CONTEXT};
use crate::net::{carries_a_key, host_port, model_place, reachable_addresses, ModelPlace};
use crate::pairing::Pairings;
use crate::paths::{same_address, write_private, Paths};
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
    pub model: ModelOptions,
    pub policy: Option<Policy>,
    pub assume_yes: bool,
    pub no_service: bool,
}

/// What the owner may say about the model instead of being asked: where it is, which one, the file holding the key
/// its service asks for, and its context window when the service does not state one.
#[derive(Clone, Debug, Default)]
pub struct ModelOptions {
    pub url: Option<String>,
    pub name: Option<String>,
    pub key_file: Option<PathBuf>,
    pub context: Option<u32>,
    pub assume_yes: bool,
}

impl ModelOptions {
    /// Whether the owner said anything at all, as opposed to asking what is set.
    pub fn says_nothing(&self) -> bool {
        self.url.is_none() && self.name.is_none() && self.key_file.is_none() && self.context.is_none()
    }
}

/// One address to look for a model at: what to call it, where it is, and whether the owner pointed at it, which
/// decides whether its failures are worth printing.
struct ModelHost {
    label: String,
    url: String,
    pointed_at: bool,
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

/// Whether the model answers a tiny request, giving a model server time to load it; the reason when it does not.
async fn answers(model: &Model, key: Option<&str>) -> Result<(), String> {
    let brain = Brain::with_key(model.clone(), key.map(str::to_string));
    let check = brain.ask_json("Reply with JSON only.", "Reply with {\"ok\": true}", 20);
    match tokio::time::timeout(Duration::from_secs(180), check).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(error)) => Err(error.to_string()),
        Err(_) => Err("it did not answer in three minutes".into()),
    }
}

/// An address as it is kept and compared: trimmed, without a trailing slash.
fn tidy(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

/// The key in the file the owner named.
fn read_key(file: &std::path::Path) -> Result<String, String> {
    let key = std::fs::read_to_string(file).map_err(|error| format!("Could not read {}: {error}", file.display()))?.trim().to_string();
    if key.is_empty() {
        return Err(format!("{} is empty: it should hold the key the model service gave you.", file.display()));
    }
    Ok(key)
}

/// Where to look for a model: the address the owner gave, else the one set before and then the model servers
/// usually found on this machine.
fn model_hosts(previous: Option<&Model>, asked: Option<&str>) -> Vec<ModelHost> {
    if let Some(url) = asked {
        return vec![ModelHost { label: "the model server".into(), url: tidy(url), pointed_at: true }];
    }
    let before = previous.map(|model| ModelHost { label: "the model set before".into(), url: tidy(&model.url), pointed_at: true });
    let usual = MODEL_HOSTS.iter().map(|(label, url)| ModelHost { label: label.to_string(), url: url.to_string(), pointed_at: false });
    let kept = before.as_ref().map(|host| host.url.clone());
    before.into_iter().chain(usual.filter(|host| Some(&host.url) != kept.as_ref())).collect()
}

/// What the owner is told before a model outside their networks is used, and what they agree to; an address that is
/// not https:// is said to carry it unprotected.
pub fn outside_notice(host: &str, url: &str) -> String {
    let unprotected = if url.trim_start().to_lowercase().starts_with("https://") {
        ""
    } else {
        " It will cross the internet unprotected, because the address is not https://."
    };
    format!(
        "{host} is outside your network. To write recaps and answers, Crucible Server will send it the subtitles of episodes \
people here have finished and of the one they are watching up to where they paused, the names of shows and episodes, Plex's \
synopses and cast lists, and the questions they ask. No Plex account, token or file is sent.{unprotected}"
    )
}

/// The entry a listing has for the model called `name`: under exactly that id, else as the last part of a path-like
/// id, since a service may list "models/name" and answer to "name".
fn listed_as<'a>(models: &'a [Listed], name: &str) -> Option<&'a Listed> {
    models.iter().find(|model| model.id == name).or_else(|| models.iter().find(|model| model.id.rsplit('/').next() == Some(name)))
}

/// The model the owner named at this address, with the window the listing states for it; named but unlisted, it is
/// still tried, since a service may list its models under other ids than it answers to.
fn named(models: &[Listed], wanted: &str) -> Listed {
    Listed { id: wanted.to_string(), context: listed_as(models, wanted).and_then(|model| model.context) }
}

/// Looks for a model that answers at one address. A model the owner names is taken as named; the one set before at
/// this address is taken again while the address still lists it, and keeps the context window it had unless a new
/// one is stated; otherwise each candidate is asked about, best first.
async fn pick_at(host: &ModelHost, key: Option<&str>, asked_for: Option<&str>, before: Option<&Model>, options: &ModelOptions) -> Option<Model> {
    let probe = Brain::with_key(Model { url: host.url.clone(), name: String::new(), context: DEFAULT_CONTEXT }, key.map(str::to_string));
    let models = match probe.listed().await {
        Ok(models) => models,
        Err(error) => {
            if host.pointed_at {
                println!("{}: {error}.", host.label);
            }
            return None;
        }
    };
    println!("Found {} at {} with {} models.", host.label, host.url, models.len());
    let outside = matches!(model_place(&host.url), ModelPlace::Outside(_));
    let still_listed = before.filter(|model| listed_as(&models, &model.name).is_some()).map(|model| model.name.as_str());
    let wanted = asked_for.or(still_listed);
    let offered = match wanted {
        Some(wanted) => vec![named(&models, wanted)],
        None if outside => {
            println!("Say which of them to use: add --model to setup, or --name to crucible-server model.");
            return None;
        }
        None => candidates(&models, None).into_iter().take(4).collect(),
    };
    for candidate in offered {
        if !(options.assume_yes || wanted.is_some() || confirm(&format!("Use {} for recaps and answers?", candidate.id), true)) {
            continue;
        }
        let window_before = before.filter(|model| model.name == candidate.id).map(|model| model.context);
        let window = options.context.or(candidate.context).or(window_before);
        let model = Model { url: host.url.clone(), name: candidate.id.clone(), context: window.unwrap_or(DEFAULT_CONTEXT) };
        println!("Checking {} (a model can take a few minutes to load)...", candidate.id);
        match answers(&model, key).await {
            Ok(()) => {
                if outside && window.is_none() {
                    println!("{} does not state its context window, so 8K is assumed and long episodes are sampled. State it with --model-context (setup) or --context (model).", host.label);
                }
                return Some(model);
            }
            Err(reason) => println!("{} did not pass the check: {reason}.", candidate.id),
        }
    }
    None
}

/// Chooses the model and files its key. A key travels only to the address it was given for: the one in the file the
/// owner named goes to the address they pointed at or the one set before, never to an address setup merely tries,
/// and otherwise only the key kept for that same address is used. A model outside the owner's networks is used only
/// when the owner agrees to what it is sent, and a refusal of the one set before ends its use. An address the owner
/// pointed at that fails is an error and changes nothing; with no address given, a model set before is kept when
/// nothing answers.
async fn settle_model(paths: &Paths, previous: Option<&Model>, options: &ModelOptions) -> Result<Option<Model>, String> {
    let named_key = match &options.key_file {
        Some(file) => Some(read_key(file)?),
        None => None,
    };
    if named_key.is_some() && options.url.is_none() && previous.is_none() {
        return Err("A key was given without the address it is for: say where the model is with --model-url (setup) or --url (model).".into());
    }
    let mut refused_the_one_before = false;
    for host in model_hosts(previous, options.url.as_deref()) {
        let before = previous.filter(|model| same_address(&model.url, &host.url));
        let key = key_at(&host, named_key.as_deref(), paths);
        if !host.url.starts_with("http://") && !host.url.starts_with("https://") {
            return Err(format!("{} is not an address: it should start with http:// or https://.", host.url));
        }
        if key.is_some() && !carries_a_key(&host.url) {
            return Err(format!("A key would cross the internet unprotected to {}: use its https:// address.", host.url));
        }
        if let ModelPlace::Outside(outside) = model_place(&host.url) {
            println!("{}", outside_notice(&outside, &host.url));
            if !(options.assume_yes || confirm("Use it?", false)) {
                refused_the_one_before |= before.is_some();
                continue;
            }
        }
        if let Some(model) = pick_at(&host, key.as_deref(), options.name.as_deref(), before, options).await {
            paths.keep_model_key(&model.url, key.as_deref()).map_err(|error| error.to_string())?;
            return Ok(Some(model));
        }
    }
    left_with(paths, options.url.as_deref(), previous, refused_the_one_before)
}

/// The key to use at one address: the one in the file the owner named, only at an address they pointed at or the one
/// set before and never at one setup merely tries; else the key kept for that same address.
fn key_at(host: &ModelHost, named_key: Option<&str>, paths: &Paths) -> Option<String> {
    named_key.filter(|_| host.pointed_at).map(str::to_string).or_else(|| paths.model_key_for(&host.url))
}

/// What the owner is left with when no model was chosen: no model and no kept key when they refused the outside one
/// set before, however they got to the question; an error and no change when an address they pointed at failed; and
/// otherwise the one set before.
fn left_with(paths: &Paths, pointed_at: Option<&str>, previous: Option<&Model>, refused_the_one_before: bool) -> Result<Option<Model>, String> {
    match (pointed_at, previous) {
        (_, Some(model)) if refused_the_one_before => {
            paths.keep_model_key(&model.url, None).map_err(|error| error.to_string())?;
            println!("{} at {} is no longer used, and its key is forgotten.", model.name, model.url);
            Ok(None)
        }
        (Some(url), _) => Err(format!("No model was set from {}; nothing changed.", tidy(url))),
        (None, Some(model)) => {
            println!("Kept {} at {}, which did not answer just now.", model.name, model.url);
            Ok(Some(model.clone()))
        }
        (None, None) => Ok(None),
    }
}

/// The window the server at `url` states for `name`, or the one assumed when it states none.
async fn stated_window(url: &str, name: &str, key: Option<&str>) -> u32 {
    let probe = Brain::with_key(Model { url: url.into(), name: name.into(), context: DEFAULT_CONTEXT }, key.map(str::to_string));
    probe.listed().await.ok().map(|models| named(&models, name)).and_then(|listed| listed.context).unwrap_or(DEFAULT_CONTEXT)
}

/// The model `summarize` judges. With an address and a name it is that model, with the key in the named file or the
/// one kept for that address, and an address outside the owner's networks is announced and agreed to first unless it
/// is the one already set. With only a name it is another model of the server that is set; with neither, the model
/// that is set. An address without a name is refused rather than answered by some other server.
pub async fn model_to_judge(
    paths: &Paths,
    url: Option<String>,
    name: Option<String>,
    key_file: Option<&std::path::Path>,
    assume_yes: bool,
) -> Result<Brain, String> {
    let set = Config::load(&paths.config()).ok().and_then(|config| config.usable_model().ok().flatten().cloned());
    let named_key = match key_file {
        Some(file) => Some(read_key(file)?),
        None => None,
    };
    let (url, name, window) = match (url, name, &set) {
        (Some(url), Some(name), _) => (tidy(&url), name, None),
        (Some(_), None, _) => return Err("Say which model at that address with --model.".into()),
        (None, Some(name), Some(set)) => (tidy(&set.url), name, None),
        (None, None, Some(set)) => (tidy(&set.url), set.name.clone(), Some(set.context)),
        (None, _, None) => return Err("Give --model-url and --model, or set a model first with crucible-server model.".into()),
    };
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return Err(format!("{url} is not an address: it should start with http:// or https://."));
    }
    let key = named_key.or_else(|| paths.model_key_for(&url));
    if key.is_some() && !carries_a_key(&url) {
        return Err(format!("A key would cross the internet unprotected to {url}: use its https:// address."));
    }
    let already_agreed = set.as_ref().is_some_and(|set| same_address(&set.url, &url));
    if let (ModelPlace::Outside(host), false) = (model_place(&url), already_agreed) {
        println!("{}", outside_notice(&host, &url));
        if !(assume_yes || confirm("Use it?", false)) {
            return Err("Nothing was sent.".into());
        }
    }
    let context = match window {
        Some(window) => window,
        None => stated_window(&url, &name, key.as_deref()).await,
    };
    Ok(Brain::with_key(Model { url, name, context }, key))
}

/// One line saying where a model is, for the owner.
fn described(model: &Model, has_key: bool) -> String {
    match model_place(&model.url) {
        ModelPlace::Own => format!("{} at {}", model.name, model.url),
        ModelPlace::Outside(host) => {
            format!("{} at {} (outside your network, at {host}{})", model.name, model.url, if has_key { ", with your key" } else { "" })
        }
    }
}

/// `crucible-server model`: says what is set and whether it answers, or changes the model, its key or its window
/// without signing in to Plex again, then restarts the service so it takes effect.
pub async fn model(paths: &Paths, options: ModelOptions, off: bool) -> Result<(), String> {
    let mut config = Config::load_set_up(&paths.config())?;
    if off {
        if let Some(model) = &config.model {
            paths.keep_model_key(&model.url, None).map_err(|error| error.to_string())?;
        }
        config.use_model(None);
        config.save(&paths.config()).map_err(|error| error.to_string())?;
        println!("Model: none. Skips still work; recaps and answers are off.");
        return restart_for_the_change();
    }
    if options.says_nothing() {
        return show_model(paths, &config).await;
    }
    let previous = config.model.clone();
    let mut pointed = options.clone();
    pointed.url = pointed.url.or_else(|| previous.as_ref().map(|model| model.url.clone()));
    if pointed.url.is_none() {
        return Err("No model is set yet: say where one is with --url, such as http://127.0.0.1:11434/v1 for Ollama.".into());
    }
    let settled = settle_model(paths, previous.as_ref(), &pointed).await?;
    match &settled {
        Some(model) => println!("Model: {}.", described(model, paths.model_key_for(&model.url).is_some())),
        None => println!("Model: none. Skips still work; recaps and answers are off."),
    }
    config.use_model(settled);
    config.save(&paths.config()).map_err(|error| error.to_string())?;
    restart_for_the_change()
}

/// Says which model is set and asks it a tiny question, since a server can list a model it cannot run. A model
/// outside the owner's networks that was never agreed to is named as unused and not asked anything.
async fn show_model(paths: &Paths, config: &Config) -> Result<(), String> {
    let model = match config.usable_model() {
        Ok(Some(model)) => model,
        Ok(None) => {
            println!("Model: none. Set one with crucible-server model --url, such as http://127.0.0.1:11434/v1 for Ollama.");
            return Ok(());
        }
        Err(unused) => {
            println!("Model: not used, because {unused}.");
            return Ok(());
        }
    };
    let key = paths.model_key_for(&model.url);
    println!("Model: {}, {}K window.", described(model, key.is_some()), model.context / 1024);
    println!("Asking it (a model can take a few minutes to load)...");
    match answers(model, key.as_deref()).await {
        Ok(()) => println!("It answers."),
        Err(reason) => println!("It does not answer: {reason}."),
    }
    Ok(())
}

/// Restarts the service so a changed model takes effect, or says to when this user runs none.
fn restart_for_the_change() -> Result<(), String> {
    match service::restart() {
        Ok(true) => println!("Crucible Server restarted with the change."),
        Ok(false) => println!("Restart Crucible Server (or its container) for the change to take effect."),
        Err(error) => println!("Could not restart the service ({error}); restart Crucible Server for the change to take effect."),
    }
    Ok(())
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

    let model_options = ModelOptions { assume_yes: options.assume_yes || options.model.assume_yes, ..options.model.clone() };
    match settle_model(paths, config.model.as_ref(), &model_options).await {
        Ok(model) => config.use_model(model),
        Err(reason) => println!("{reason}"),
    }
    match &config.model {
        Some(model) => println!("Model: {}.", described(model, paths.model_key_for(&model.url).is_some())),
        None => println!("Model: none yet. Skips work now; recaps and answers start once a model is set (crucible-server model --url)."),
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
    use crate::brain::testing;

    fn pointed(url: &str, name: &str) -> ModelOptions {
        ModelOptions { url: Some(url.into()), name: Some(name.into()), ..ModelOptions::default() }
    }

    fn keys_received(service: &testing::Service) -> Vec<Option<String>> {
        service.received.lock().unwrap().iter().map(|request| request.key.clone()).collect()
    }

    #[tokio::test]
    async fn a_kept_key_travels_only_to_the_address_it_was_kept_for() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let first = testing::open(&["writer"]).await;
        let second = testing::open(&["writer"]).await;
        let key_file = dir.path().join("given-key");
        std::fs::write(&key_file, "sk-first\n").unwrap();

        let with_file = ModelOptions { key_file: Some(key_file), ..pointed(&format!("{}/", first.url), "writer") };
        let set = settle_model(&paths, None, &with_file).await.unwrap().unwrap();
        assert_eq!(set, Model { url: first.url.clone(), name: "writer".into(), context: 131_072 });
        assert_eq!(paths.model_key_for(&first.url).as_deref(), Some("sk-first"));
        assert_eq!(paths.model_key_for(&second.url), None);
        assert!(keys_received(&first).iter().all(|key| key.as_deref() == Some("sk-first")));

        let again = settle_model(&paths, Some(&set), &ModelOptions::default()).await.unwrap().unwrap();
        assert_eq!(again, set);
        assert!(keys_received(&first).iter().all(|key| key.as_deref() == Some("sk-first")));

        let moved = settle_model(&paths, Some(&set), &pointed(&second.url, "writer")).await.unwrap().unwrap();
        assert_eq!(moved.url, second.url);
        assert!(!keys_received(&second).is_empty() && keys_received(&second).iter().all(Option::is_none));
        assert_eq!(paths.model_key_for(&first.url), None);
        assert_eq!(paths.model_key_for(&second.url), None);
    }

    #[tokio::test]
    async fn a_key_kept_for_one_address_is_not_sent_to_another_the_config_names() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let edited_to = testing::open(&["writer"]).await;
        paths.keep_model_key("https://openrouter.ai/api/v1", Some("sk-kept")).unwrap();
        let brain = Brain::with_stored_key(Model { url: edited_to.url.clone(), name: "writer".into(), context: 8192 }, &paths);
        assert!(!brain.sends_key());
        assert!(brain.ask_json("s", "u", 20).await.is_ok());
        assert!(keys_received(&edited_to).iter().all(Option::is_none));
    }

    #[tokio::test]
    async fn an_address_that_fails_changes_nothing_and_a_key_never_goes_out_in_the_clear() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let previous = Model { url: "http://127.0.0.1:9/v1".into(), name: "writer".into(), context: 8192 };
        paths.keep_model_key(&previous.url, Some("sk-kept")).unwrap();

        let unreachable = settle_model(&paths, Some(&previous), &pointed("http://127.0.0.1:9/v1", "writer")).await;
        assert!(unreachable.unwrap_err().contains("nothing changed"));
        assert_eq!(paths.model_key_for(&previous.url).as_deref(), Some("sk-kept"));

        let key_file = dir.path().join("given-key");
        std::fs::write(&key_file, "sk-new").unwrap();
        let in_the_clear = ModelOptions { key_file: Some(key_file.clone()), ..pointed("http://models.example.com/v1", "writer") };
        assert!(settle_model(&paths, None, &in_the_clear).await.unwrap_err().contains("https://"));

        let not_an_address = settle_model(&paths, None, &pointed("models.example.com/v1", "writer")).await;
        assert!(not_an_address.unwrap_err().contains("not an address"));

        std::fs::write(&key_file, " \n").unwrap();
        let empty = ModelOptions { key_file: Some(key_file), ..pointed("https://models.example.com/v1", "writer") };
        assert!(settle_model(&paths, None, &empty).await.unwrap_err().contains("is empty"));
        assert_eq!(paths.model_key_for(&previous.url).as_deref(), Some("sk-kept"));
    }

    #[tokio::test]
    async fn a_model_set_before_is_looked_for_first_and_keeps_its_window() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let gone = Model { url: "http://127.0.0.1:9/v1".into(), name: "writer".into(), context: 8192 };
        let hosts = model_hosts(Some(&gone), None);
        assert_eq!(hosts[0].url, gone.url);
        assert!(hosts[0].pointed_at && hosts[1..].iter().all(|host| !host.pointed_at && host.url != gone.url));
        let asked: Vec<String> = model_hosts(Some(&gone), Some("https://openrouter.ai/api/v1/")).into_iter().map(|host| host.url).collect();
        assert_eq!(asked, vec!["https://openrouter.ai/api/v1"]);

        let silent_about_windows = testing::start_listing(serde_json::json!({"data": [{"id": "writer"}]})).await;
        let stated = ModelOptions { context: Some(200_000), ..pointed(&silent_about_windows.url, "writer") };
        let set = settle_model(&paths, None, &stated).await.unwrap().unwrap();
        assert_eq!(set.context, 200_000);
        let key_only = ModelOptions { url: Some(set.url.clone()), ..ModelOptions::default() };
        assert_eq!(settle_model(&paths, Some(&set), &key_only).await.unwrap().unwrap().context, 200_000);
        let other_model = settle_model(&paths, Some(&set), &pointed(&set.url, "another")).await.unwrap().unwrap();
        assert_eq!(other_model.context, DEFAULT_CONTEXT);
    }

    #[tokio::test]
    async fn the_model_to_judge_is_the_one_named_and_never_another_server_with_its_key() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let set_one = testing::open(&["writer"]).await;
        let typed = testing::open(&["judge"]).await;
        let mut config = Config::new("test");
        config.use_model(Some(Model { url: set_one.url.clone(), name: "writer".into(), context: 65_536 }));
        config.save(&paths.config()).unwrap();
        paths.keep_model_key(&set_one.url, Some("sk-set")).unwrap();
        let key_file = dir.path().join("typed-key");
        std::fs::write(&key_file, "sk-typed").unwrap();

        let unnamed = model_to_judge(&paths, Some(typed.url.clone()), None, Some(&key_file), true).await;
        assert!(unnamed.err().unwrap().contains("--model"));
        assert!(keys_received(&set_one).is_empty() && keys_received(&typed).is_empty());

        let judged = model_to_judge(&paths, Some(typed.url.clone()), Some("judge".into()), Some(&key_file), true).await.unwrap();
        assert_eq!(judged.model, Model { url: typed.url.clone(), name: "judge".into(), context: 131_072 });
        assert!(judged.ask_json("s", "u", 20).await.is_ok());
        assert!(keys_received(&typed).iter().all(|key| key.as_deref() == Some("sk-typed")));
        assert!(keys_received(&set_one).is_empty());

        let other_server_no_key = model_to_judge(&paths, Some(typed.url.clone()), Some("judge".into()), None, true).await.unwrap();
        assert!(!other_server_no_key.sends_key());

        let the_set_one = model_to_judge(&paths, None, None, None, false).await.unwrap();
        assert_eq!(the_set_one.model.context, 65_536);
        assert!(the_set_one.ask_json("s", "u", 20).await.is_ok());
        assert!(keys_received(&set_one).iter().all(|key| key.as_deref() == Some("sk-set")));

        let its_sibling = model_to_judge(&paths, None, Some("sibling".into()), None, false).await.unwrap();
        assert_eq!((its_sibling.model.url.as_str(), its_sibling.model.name.as_str()), (set_one.url.as_str(), "sibling"));

        let in_the_clear = model_to_judge(&paths, Some("http://models.example.com/v1".into()), Some("m".into()), Some(&key_file), true).await;
        assert!(in_the_clear.err().unwrap().contains("https://"));
        let nothing_set = Paths::at(&dir.path().join("empty"));
        assert!(model_to_judge(&nothing_set, None, None, None, true).await.err().unwrap().contains("crucible-server model"));
    }

    #[test]
    fn refusing_the_outside_model_set_before_ends_its_use_and_forgets_its_key() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let outside = Model { url: "https://models.example.invalid/v1".into(), name: "writer".into(), context: 8192 };
        assert!(matches!(model_place(&model_hosts(Some(&outside), None)[0].url), ModelPlace::Outside(_)));

        paths.keep_model_key(&outside.url, Some("sk-kept")).unwrap();
        assert_eq!(left_with(&paths, None, Some(&outside), false).unwrap(), Some(outside.clone()));
        assert_eq!(paths.model_key_for(&outside.url).as_deref(), Some("sk-kept"));

        assert_eq!(left_with(&paths, None, Some(&outside), true).unwrap(), None);
        assert_eq!(paths.model_key_for(&outside.url), None);

        paths.keep_model_key(&outside.url, Some("sk-kept")).unwrap();
        assert_eq!(left_with(&paths, Some(&outside.url), Some(&outside), true).unwrap(), None);
        assert_eq!(paths.model_key_for(&outside.url), None);

        paths.keep_model_key(&outside.url, Some("sk-kept")).unwrap();
        assert!(left_with(&paths, Some("https://other.example/v1/"), Some(&outside), false).unwrap_err().contains("https://other.example/v1;"));
        assert_eq!(paths.model_key_for(&outside.url).as_deref(), Some("sk-kept"));
        assert_eq!(left_with(&paths, None, None, false).unwrap(), None);
    }

    #[tokio::test]
    async fn a_key_from_a_file_goes_only_to_an_address_the_owner_pointed_at() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let key_file = dir.path().join("given-key");
        std::fs::write(&key_file, "sk-given").unwrap();

        let no_address = ModelOptions { key_file: Some(key_file.clone()), ..ModelOptions::default() };
        assert!(settle_model(&paths, None, &no_address).await.unwrap_err().contains("without the address it is for"));

        let host = |pointed_at: bool| ModelHost { label: "a model server".into(), url: "http://127.0.0.1:9/v1".into(), pointed_at };
        assert_eq!(key_at(&host(false), Some("sk-given"), &paths), None);
        assert_eq!(key_at(&host(true), Some("sk-given"), &paths).as_deref(), Some("sk-given"));
        paths.keep_model_key("http://127.0.0.1:9/v1", Some("sk-kept-here")).unwrap();
        assert_eq!(key_at(&host(false), Some("sk-given"), &paths).as_deref(), Some("sk-kept-here"));
        assert!(model_hosts(None, None).iter().all(|usual| !usual.pointed_at));
        paths.keep_model_key("http://127.0.0.1:9/v1", None).unwrap();

        let before = testing::open(&["writer"]).await;
        let previous = Model { url: before.url.clone(), name: "writer".into(), context: 131_072 };
        let rekeyed = settle_model(&paths, Some(&previous), &no_address).await.unwrap().unwrap();
        assert_eq!(rekeyed, previous);
        assert!(keys_received(&before).iter().all(|key| key.as_deref() == Some("sk-given")));
        assert_eq!(paths.model_key_for(&before.url).as_deref(), Some("sk-given"));
    }

    #[tokio::test]
    async fn a_model_the_server_no_longer_lists_gives_way_to_the_ones_it_does() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let server = testing::open(&["qwen3-30b-a3b"]).await;
        let removed = Model { url: server.url.clone(), name: "gemma4-26b-a4b-gguf".into(), context: 8192 };
        let agreeing = ModelOptions { url: Some(server.url.clone()), assume_yes: true, ..ModelOptions::default() };
        let chosen = settle_model(&paths, Some(&removed), &agreeing).await.unwrap().unwrap();
        assert_eq!(chosen.name, "qwen3-30b-a3b");

        let both = vec![Listed { id: "vendor/writer".into(), context: Some(8_192) }, Listed { id: "writer".into(), context: Some(131_072) }];
        assert_eq!(named(&both, "writer").context, Some(131_072));
        assert_eq!(listed_as(&both[..1], "writer").map(|listed| listed.id.as_str()), Some("vendor/writer"));
    }

    #[test]
    fn says_plainly_what_leaves_for_a_model_outside_and_names_an_unlisted_model_anyway() {
        let notice = outside_notice("openrouter.ai", "https://openrouter.ai/api/v1");
        assert!(notice.contains("openrouter.ai is outside your network") && notice.contains("subtitles") && notice.contains("No Plex account"));
        assert!(notice.contains("the one they are watching up to where they paused") && notice.contains("names of shows and episodes"));
        assert!(!notice.contains("unprotected") && outside_notice("8.8.8.8", "http://8.8.8.8/v1").contains("cross the internet unprotected"));
        let listed = vec![Listed { id: "models/gemini-flash".into(), context: Some(1_048_576) }];
        assert_eq!(named(&listed, "gemini-flash"), Listed { id: "gemini-flash".into(), context: Some(1_048_576) });
        assert_eq!(named(&listed, "elsewhere"), Listed { id: "elsewhere".into(), context: None });
        let outside = Model { url: "https://openrouter.ai/api/v1".into(), name: "m".into(), context: 8192 };
        assert_eq!(described(&outside, true), "m at https://openrouter.ai/api/v1 (outside your network, at openrouter.ai, with your key)");
        assert_eq!(described(&Model { url: "http://127.0.0.1:8081/v1".into(), ..outside }, false), "m at http://127.0.0.1:8081/v1");
    }

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
