//! `crucible-server sports`: where sports research stands, the changes the owner makes from the terminal, and a dry
//! research of one file name to judge a model before letting it write.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use super::checks::State;
use super::record::days_from_civil;
use super::release::Release;
use super::research::{research, Step};
use super::runner::Sports;
use super::web::{Engine, Web};
use crate::brain::Brain;
use crate::config::Config;
use crate::paths::{write_private, Paths};
use crate::plex::Plex;
use crate::store::Store;
use crate::{service, setup, terminal};

/// What the owner asked for on the command line.
#[derive(Default)]
pub struct Options {
    pub searxng: Option<String>,
    pub brave_key_file: Option<PathBuf>,
    pub libraries: Vec<String>,
    pub on: bool,
    pub off: bool,
    pub agree: bool,
    pub try_name: Option<String>,
}

impl Options {
    fn changes_anything(&self) -> bool {
        self.searxng.is_some() || self.brave_key_file.is_some() || !self.libraries.is_empty() || self.on || self.off || self.agree
    }
}

pub async fn run(paths: &Paths, options: Options) -> Result<(), String> {
    let mut config = Config::load_set_up(&paths.config())?;
    let client = setup::client_id(paths).map_err(|error| error.to_string())?;
    let plex = Plex::new(&config.plex_url, &client);
    let owner_token = std::fs::read_to_string(paths.plex_token()).ok().map(|token| token.trim().to_string());
    if let Some(name) = &options.try_name {
        return try_one(paths, &config, name).await;
    }
    if options.changes_anything() {
        change(paths, &mut config, &plex, owner_token.as_deref(), &options).await?;
        config.save(&paths.config()).map_err(|error| error.to_string())?;
        match service::restart() {
            Ok(true) => println!("Crucible Server restarted with the change.\n"),
            Ok(false) => println!("Restart Crucible Server (or its container) for the change to take effect.\n"),
            Err(error) => println!("Could not restart the service ({error}); restart Crucible Server for the change to take effect.\n"),
        }
    }
    let store = Arc::new(Store::open(&paths.database()).map_err(|error| error.to_string())?);
    let sports = Sports::new(paths.clone(), &config, plex, store, owner_token);
    println!("Sports research (asking the model can take a minute while it loads)...\n");
    for check in sports.checks(true).await {
        let mark = if check.state == State::Done { "✓" } else { "✗" };
        println!("{mark} {:<11} {}", check.id, check.detail);
        if let Some(fix) = check.fix {
            println!("  {:<11} {fix}", "");
        }
    }
    let (items, counts) = sports.items(10);
    if !counts.is_empty() {
        println!("\n{}", counts.iter().map(|(state, count)| format!("{count} {state}")).collect::<Vec<_>>().join(", "));
        for item in items {
            println!("  {:<9} {}{}", item.state, item.title, if item.note.is_empty() { String::new() } else { format!(" ({})", item.note) });
        }
    }
    Ok(())
}

async fn change(paths: &Paths, config: &mut Config, plex: &Plex, owner_token: Option<&str>, options: &Options) -> Result<(), String> {
    let sports = &mut config.sports;
    if let Some(url) = &options.searxng {
        let url = url.trim().trim_end_matches('/').to_string();
        reqwest::Url::parse(&url).map_err(|_| format!("{url} is not an address, such as http://127.0.0.1:8888"))?;
        sports.engine = Some(Engine::Searxng { url });
    }
    if let Some(file) = &options.brave_key_file {
        let key = std::fs::read_to_string(file).map_err(|error| format!("{}: {error}", file.display()))?;
        write_private(&paths.search_key(), key.trim().as_bytes()).map_err(|error| error.to_string())?;
        sports.engine = Some(Engine::Brave);
    }
    if !options.libraries.is_empty() {
        let token = owner_token.ok_or("The server has no Plex sign-in: run crucible-server setup first.")?;
        let sections = plex.sections(token).await.map_err(|error| error.to_string())?;
        let mut chosen = Vec::new();
        for name in &options.libraries {
            let section = sections
                .iter()
                .find(|section| section.title.eq_ignore_ascii_case(name.trim()) || section.key == name.trim())
                .ok_or_else(|| format!("Plex has no library called {name}."))?;
            if !section.is_other_videos() {
                return Err(format!("{} is not an Other Videos library; sports research reads only those.", section.title));
            }
            chosen.push(section.key.clone());
        }
        sports.libraries = chosen;
    }
    if let Some(engine) = sports.engine.clone() {
        if !sports.agreed_to_engine() {
            let notice = format!(
                "Sports research sends searches naming the events in your sports files (such as \"UFC 334 prelims\") to {}, and reads public web pages from this machine. Your library, files and watch history are not sent.",
                engine.destination()
            );
            println!("{notice}");
            if options.agree || terminal::confirm("Agree?", false) {
                sports.agreed = Some(engine.destination());
            }
        }
    }
    if options.on {
        sports.on = true;
    }
    if options.off {
        sports.on = false;
    }
    Ok(())
}

/// Researches one file name with the configured model and search engine and prints the record and what Plex would
/// show, without writing anything.
async fn try_one(paths: &Paths, config: &Config, name: &str) -> Result<(), String> {
    let model = config.usable_model()?.ok_or("No model is set: crucible-server model --url")?;
    let engine = config.sports.engine.clone().ok_or("No search engine is set: crucible-server sports --searxng <url>")?;
    if !config.sports.agreed_to_engine() {
        return Err("Agree to where searches go first: crucible-server sports --agree".into());
    }
    let key = matches!(engine, Engine::Brave).then(|| std::fs::read_to_string(paths.search_key()).ok()).flatten();
    let web = Web::new(engine, key);
    let brain = Brain::with_stored_key(model.clone(), paths);
    let release = Release::read(name);
    let started = Instant::now();
    println!("Researching {} with {}...", release.cleaned, model.name);
    let printing = |step: Step| match step {
        Step::Searching(query) => println!("  searching: {query}"),
        Step::Reading(url) => println!("  reading:   {url}"),
        Step::Checking => println!("  checking the record"),
        Step::Thinking => {}
    };
    let today = crate::store::now().div_euclid(86_400);
    let done = research(&brain, &web, &release, "", today.max(days_from_civil(1970, 1, 2)), &printing).await.map_err(|error| error.to_string())?;
    println!("\n{}", serde_json::to_string_pretty(&done.record).unwrap_or_default());
    let desired = done.record.render(release.event.is_some());
    println!(
        "\nPlex would show:\n  Title:   {}\n  Date:    {}\n  Sort:    {}\n  Poster:  {}\n\n{}",
        desired.title,
        desired.date,
        desired.title_sort,
        desired.poster.as_deref().unwrap_or("none"),
        desired.summary
    );
    println!("\n{:.0} s, {} searches, {} pages, {} turns.", started.elapsed().as_secs_f64(), done.searches, done.reads, done.turns);
    Ok(())
}
