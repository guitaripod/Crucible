use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};

use crucible_server::brain::Brain;
use crucible_server::config::{Config, Model, Policy, DEFAULT_CONTEXT};
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
        /// An OpenAI-compatible model server, such as http://127.0.0.1:11434/v1 for Ollama.
        #[arg(long)]
        model_url: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long, value_enum)]
        policy: Option<PolicyArgument>,
        /// Take every default without asking.
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
        #[arg(long)]
        model_url: Option<String>,
        #[arg(long)]
        model: Option<String>,
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
    let config = Config::load(&paths.config()).map_err(|error| format!("{error}. Run crucible-server setup first."))?;
    let store = Store::open(&paths.database()).map_err(|error| error.to_string())?;
    Ok((config, store))
}

async fn run(command: Command, paths: Paths) -> Result<(), String> {
    match command {
        Command::Setup { plex_url, token_file, model_url, model, policy, yes, no_service } => {
            let policy = policy.map(|policy| match policy {
                PolicyArgument::OnlyMe => Policy::OnlyMe,
                PolicyArgument::MyPlexHome => Policy::MyPlexHome,
                PolicyArgument::Everyone => Policy::Everyone,
            });
            setup::run(&paths, setup::Options { plex_url, token_file, model_url, model, policy, assume_yes: yes, no_service }).await
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
        Command::Summarize { file, show, title, synopsis, characters, model_url, model } => {
            let configured = Config::load(&paths.config()).ok().and_then(|config| config.model);
            let model = match (model_url, model, configured) {
                (Some(url), Some(name), _) => {
                    let context = Brain::new(Model { url: url.clone(), name: name.clone(), context: DEFAULT_CONTEXT })
                        .listed()
                        .await
                        .ok()
                        .and_then(|listed| listed.into_iter().find(|model| model.id == name)?.context)
                        .unwrap_or(DEFAULT_CONTEXT);
                    Model { url, name, context }
                }
                (_, _, Some(model)) => model,
                _ => return Err("Give --model-url and --model, or run setup with a model first.".into()),
            };
            let lines = dialogue::local_story(&file).await.map_err(|error| error.to_string())?;
            let label = file.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
            let source = SummarySource { show, label, title, synopsis, roster: characters, lines };
            let started = std::time::Instant::now();
            let (text, grounded) = write_summary(&Brain::new(model), &source).await.map_err(|error| error.to_string())?;
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
