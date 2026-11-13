use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};

use crucible_server::config::{Config, Policy};
use crucible_server::dialogue;
use crucible_server::paths::Paths;
use crucible_server::recap::{write_summary, SummarySource};
use crucible_server::store::Store;
use crucible_server::{doctor, serve, service, setup, tls};

/// The optional companion on the Plex machine for Crucible on iPhone, iPad and Apple TV.
#[derive(Parser)]
#[command(name = "crucible-server", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, ValueEnum)]
enum PolicyArgument {
    OnlyMe,
    MyPlexHome,
    Everyone,
}

#[derive(Subcommand)]
enum Command {
    /// Sign in with Plex, choose a model, start the service and show a pairing code.
    Setup {
        #[arg(long, env = "PLEX_URL")]
        plex_url: Option<String>,
        /// Read the owner's Plex token from this file instead of signing in at plex.tv/link (a Docker secret).
        #[arg(long)]
        token_file: Option<PathBuf>,
        /// An OpenAI-compatible model server, such as http://127.0.0.1:11434/v1 for Ollama, or a hosted service's
        /// https:// address.
        #[arg(long)]
        model_url: Option<String>,
        /// The model's name as its server lists it. Needed for a hosted service; otherwise setup offers the best it finds.
        #[arg(long)]
        model: Option<String>,
        /// A file holding the key the service at --model-url asks for (a Docker secret). It is kept beside the
        /// config, readable only by this user.
        #[arg(long, env = "CRUCIBLE_MODEL_KEY_FILE")]
        model_key_file: Option<PathBuf>,
        /// The model's context window in tokens, when the service does not state it.
        #[arg(long)]
        model_context: Option<u32>,
        #[arg(long, value_enum)]
        policy: Option<PolicyArgument>,
        /// Take every default without asking, and agree to what a model outside your network is sent when
        /// --model-url names one or one was agreed to before.
        #[arg(long, short)]
        yes: bool,
        /// Do not install a service; run `serve` yourself.
        #[arg(long)]
        no_service: bool,
    },
    /// Run the server (what the service runs).
    Serve,
    /// Show a new pairing code for another device.
    Pair,
    /// List paired devices.
    Devices,
    /// Unpair a device by its id.
    Unpair { id: String },
    /// Show the model that writes recaps and answers, or change it without running setup again.
    Model {
        /// An OpenAI-compatible model server on this machine or your tailnet, or a hosted service's https:// address.
        #[arg(long)]
        url: Option<String>,
        /// The model's name as the service lists it.
        #[arg(long)]
        name: Option<String>,
        /// A file holding the key the service asks for. It is kept beside the config, readable only by this user.
        #[arg(long)]
        key_file: Option<PathBuf>,
        /// The model's context window in tokens, when the service does not state it.
        #[arg(long)]
        context: Option<u32>,
        /// Use no model: skips keep working, recaps and answers stop.
        #[arg(long)]
        off: bool,
        /// Agree to what a model outside your network is sent without being asked.
        #[arg(long, short)]
        yes: bool,
    },
    /// Check Plex, the model, ffmpeg, the certificate and the service.
    Doctor,
    /// Make a new certificate, which unpairs every device.
    RotateCertificate,
    /// Summarise a video file on this machine from its subtitles and print the checked summary, to judge a model.
    Summarize {
        file: PathBuf,
        #[arg(long, default_value = "")]
        show: String,
        #[arg(long, default_value = "")]
        title: String,
        #[arg(long, default_value = "")]
        synopsis: String,
        #[arg(long, default_value = "")]
        characters: String,
        /// Judge the model at this address instead of the one that is set; needs --model.
        #[arg(long)]
        model_url: Option<String>,
        /// The model's name as its server lists it: at --model-url, or another model of the server that is set.
        #[arg(long)]
        model: Option<String>,
        /// A file holding the key the model service asks for; without it, the key kept for that address is used.
        #[arg(long)]
        model_key_file: Option<PathBuf>,
        /// Agree to sending the episode to a model outside your network without being asked.
        #[arg(long, short)]
        yes: bool,
    },
    /// Install or remove the background service.
    Service {
        #[arg(value_enum)]
        action: ServiceAction,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum ServiceAction {
    Install,
    Uninstall,
}

fn context(paths: &Paths) -> Result<(Config, Store), String> {
    let config = Config::load_set_up(&paths.config())?;
    let store = Store::open(&paths.database()).map_err(|error| error.to_string())?;
    Ok((config, store))
}

async fn run(command: Command, paths: Paths) -> Result<(), String> {
    match command {
        Command::Setup { plex_url, token_file, model_url, model, model_key_file, model_context, policy, yes, no_service } => {
            let policy = policy.map(|policy| match policy {
                PolicyArgument::OnlyMe => Policy::OnlyMe,
                PolicyArgument::MyPlexHome => Policy::MyPlexHome,
                PolicyArgument::Everyone => Policy::Everyone,
            });
            let model = setup::ModelOptions { url: model_url, name: model, key_file: model_key_file, context: model_context, assume_yes: yes };
            setup::run(&paths, setup::Options { plex_url, token_file, model, policy, assume_yes: yes, no_service }).await
        }
        Command::Model { url, name, key_file, context, off, yes } => {
            setup::model(&paths, setup::ModelOptions { url, name, key_file, context, assume_yes: yes }, off).await
        }
        Command::Serve => serve::run(&paths).await,
        Command::Pair => {
            let (config, store) = context(&paths)?;
            let identity = tls::load_or_create(&paths, &config.name).map_err(|error| error.to_string())?;
            setup::show_pairing(&config, &identity.fingerprint, &store)
        }
        Command::Devices => {
            let (_, store) = context(&paths)?;
            let devices = store.devices().map_err(|error| error.to_string())?;
            if devices.is_empty() {
                println!("No devices are paired. Pair one with crucible-server pair.");
            }
            for device in devices {
                println!("{}  {} ({})", device.id, device.name, device.platform);
            }
            Ok(())
        }
        Command::Unpair { id } => {
            let (_, store) = context(&paths)?;
            match store.remove_device(&id).map_err(|error| error.to_string())? {
                true => {
                    println!("Unpaired {id}.");
                    Ok(())
                }
                false => Err(format!("No device {id}. See crucible-server devices.")),
            }
        }
        Command::Doctor => {
            let checks = doctor::run(&paths).await;
            let failed = checks.iter().filter(|check| !check.ok).count();
            for check in &checks {
                println!("{} {:<24} {}", if check.ok { "✓" } else { "✗" }, check.name, check.detail);
            }
            if failed == 0 {
                Ok(())
            } else {
                Err(format!("{failed} check{} failed.", if failed == 1 { "" } else { "s" }))
            }
        }
        Command::RotateCertificate => {
            let (config, store) = context(&paths)?;
            tls::create(&paths, &config.name).map_err(|error| error.to_string())?;
            let removed = store.remove_all_devices().map_err(|error| error.to_string())?;
            println!("New certificate made; {removed} devices unpaired. Restart the service, then pair again.");
            Ok(())
        }
        Command::Summarize { file, show, title, synopsis, characters, model_url, model, model_key_file, yes } => {
            let brain = setup::model_to_judge(&paths, model_url, model, model_key_file.as_deref(), yes).await?;
            let lines = dialogue::local_story(&file).await.map_err(|error| error.to_string())?;
            let label = file.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
            let source = SummarySource { show, label, title, synopsis, roster: characters, lines };
            let started = std::time::Instant::now();
            let (text, grounded) = write_summary(&brain, &source).await.map_err(|error| error.to_string())?;
            println!(
                "{text}\n\n{} · {} dialogue lines · {:.1} s",
                if grounded { "grounded" } else { "not grounded" },
                source.lines.len(),
                started.elapsed().as_secs_f64()
            );
            Ok(())
        }
        Command::Service { action: ServiceAction::Install } => {
            let at = service::install(&paths.root, &paths.log()).map_err(|error| error.to_string())?;
            println!("Installed {}.", at.display());
            Ok(())
        }
        Command::Service { action: ServiceAction::Uninstall } => service::uninstall().map_err(|error| error.to_string()),
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_env("CRUCIBLE_SERVER_LOG").unwrap_or_else(|_| "crucible_server=info".into()))
        .with_writer(std::io::stderr)
        .init();
    let paths = match Paths::discover() {
        Ok(paths) => paths,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = paths.ensure() {
        eprintln!("Could not create {}: {error}", paths.root.display());
        return ExitCode::FAILURE;
    }
    match run(cli.command, paths).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
