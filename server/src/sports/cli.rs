//! `crucible-server research` (once `sports`): where research stands, the changes the owner makes from the terminal, and a dry
//! research of one file name to judge a model before letting it write.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use super::checks::State;
use super::record::days_from_civil;
use super::release::Release;
use super::research::{research, Step};
use super::runner::Sports;
use super::schedule::{self, Week};
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
    pub schedule: Option<String>,
    pub kinds: Vec<String>,
    pub try_name: Option<String>,
    pub try_kind: Option<String>,
    pub undo: Option<String>,
    pub undo_library: Option<String>,
    pub again: Option<String>,
}

impl Options {
    fn changes_anything(&self) -> bool {
        self.searxng.is_some()
            || self.brave_key_file.is_some()
            || !self.libraries.is_empty()
            || !self.kinds.is_empty()
            || self.on
            || self.off
            || self.agree
            || self.schedule.is_some()
    }
}

pub async fn run(paths: &Paths, options: Options) -> Result<(), String> {
    let mut config = Config::load_set_up(&paths.config())?;
    let client = setup::client_id(paths).map_err(|error| error.to_string())?;
    let plex = Plex::new(&config.plex_url, &client);
    let owner_token = std::fs::read_to_string(paths.plex_token()).ok().map(|token| token.trim().to_string());
    if let Some(name) = &options.try_name {
        let kind = match options.try_kind.as_deref() {
            Some(kind) => crate::config::Kind::parse(kind).ok_or_else(|| format!("{kind} is not sports, adult or general."))?,
            None => crate::config::Kind::Sports,
        };
        if kind != crate::config::Kind::Sports {
            return try_work(paths, &config, name, kind).await;
        }
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
    if options.undo.is_some() || options.undo_library.is_some() || options.again.is_some() {
        return take_back(&options, &config, plex, store, owner_token, paths).await;
    }
    let sports = Sports::new(paths.clone(), &config, plex, store, owner_token);
    println!("Library research (asking the model can take a minute while it loads)...\n");
    for check in sports.checks(true).await {
        let mark = if check.state == State::Done { "✓" } else { "✗" };
        println!("{mark} {:<11} {}", check.id, check.detail);
        if let Some(fix) = check.fix {
            println!("  {:<11} {fix}", "");
        }
    }
    println!("{}", hours_line(&config));
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
                return Err(format!("{} is not an Other Videos library; research reads only those.", section.title));
            }
            chosen.push(section.key.clone());
        }
        sports.libraries = chosen;
    }
    if !options.kinds.is_empty() {
        let token = owner_token.ok_or("The server has no Plex sign-in: run crucible-server setup first.")?;
        let sections = plex.sections(token).await.map_err(|error| error.to_string())?;
        for assignment in &options.kinds {
            let (name, kind) = assignment.rsplit_once('=').ok_or_else(|| format!("{assignment} is not LIBRARY=KIND, such as \"Holy Grail=adult\"."))?;
            let kind = crate::config::Kind::parse(kind).ok_or_else(|| format!("{kind} is not sports, adult or general."))?;
            let section = sections
                .iter()
                .find(|section| section.title.eq_ignore_ascii_case(name.trim()) || section.key == name.trim())
                .ok_or_else(|| format!("Plex has no library called {name}."))?;
            sports.kinds.insert(section.key.clone(), kind);
        }
    }
    if let Some(engine) = sports.engine.clone() {
        if !sports.agreed_to_engine() {
            let notice = format!(
                "Research sends searches naming what is in your files (such as \"UFC 334 prelims\" or a film's title) to {}, and reads public web pages from this machine. Your library, files and watch history are not sent.",
                engine.destination()
            );
            println!("{notice}");
            if options.agree || terminal::confirm("Agree?", false) {
                sports.agreed = Some(engine.destination());
            }
        }
    }
    if let Some(text) = &options.schedule {
        sports.schedule = match text.trim().to_lowercase().as_str() {
            "always" | "any time" | "anytime" => None,
            _ => Some(Week::parse(text)?).filter(|week| !week.is_always()),
        };
    }
    if options.on {
        sports.on = true;
    }
    if options.off {
        sports.on = false;
    }
    Ok(())
}

/// The owner's undo and research-again asks from the command line.
async fn take_back(options: &Options, config: &Config, plex: Plex, store: Arc<Store>, owner_token: Option<String>, paths: &Paths) -> Result<(), String> {
    let sections = match &owner_token {
        Some(token) => plex.sections(token).await.map_err(|error| error.to_string())?,
        None => Vec::new(),
    };
    let sports = Sports::new(paths.clone(), config, plex, store.clone(), owner_token);
    let item = |name: &str| store.sports_item_named(name.trim()).map_err(|error| error.to_string())?.ok_or_else(|| format!("Research has nothing for {name}."));
    if let Some(name) = &options.undo {
        let found = item(name)?;
        sports.undo(&found.rating_key).await?;
        println!("Took research back from {}: Plex shows it as it was.", found.file.rsplit(['/', '\\']).next().unwrap_or(&found.file));
    }
    if let Some(name) = &options.again {
        let found = item(name)?;
        sports.redo(&found.rating_key);
        println!("{} is researched again on the next look at the libraries.", found.file.rsplit(['/', '\\']).next().unwrap_or(&found.file));
    }
    if let Some(name) = &options.undo_library {
        let section = sections
            .iter()
            .find(|section| section.title.eq_ignore_ascii_case(name.trim()) || section.key == name.trim())
            .ok_or_else(|| format!("Plex has no library called {name}."))?;
        println!("Taking research back from {}...", section.title);
        let (undone, failed) = sports.undo_library(&section.key).await;
        println!("Took research back from {undone} files{}.", if failed > 0 { format!("; {failed} could not be changed") } else { String::new() });
    }
    Ok(())
}

/// Researches one file name that is not sports, as a library of `kind` would, and prints the record and what Plex would
/// show, without writing anything.
async fn try_work(paths: &Paths, config: &Config, name: &str, kind: crate::config::Kind) -> Result<(), String> {
    let model = config.usable_model()?.ok_or("No model is set: crucible-server model --url")?;
    let engine = config.sports.engine.clone().ok_or("No search engine is set: crucible-server research --searxng <url>")?;
    if !config.sports.agreed_to_engine() {
        return Err("Agree to where searches go first: crucible-server research --agree".into());
    }
    let key = matches!(engine, Engine::Brave).then(|| std::fs::read_to_string(paths.search_key()).ok()).flatten();
    let web = Web::new(engine, key);
    let brain = Brain::with_stored_key(model.clone(), paths);
    let work = super::work::Work::read(name);
    let started = Instant::now();
    println!("Researching {} as {} with {}...", work.cleaned, kind.name(), model.name);
    let printing = |step: Step| match step {
        Step::Searching(query) => println!("  searching: {query}"),
        Step::Reading(url) => println!("  reading:   {url}"),
        Step::Checking => println!("  checking the record"),
        Step::Thinking => {}
    };
    let today = crate::store::now().div_euclid(86_400);
    let (record, took) = super::work::research_work(&brain, &web, kind, &work, "", "", today.max(days_from_civil(1970, 1, 2)), &printing)
        .await
        .map_err(|error| error.to_string())?;
    println!("\n{}", serde_json::to_string_pretty(&record).unwrap_or_default());
    let desired = record.render();
    println!(
        "\nPlex would show:\n  Title:   {}\n  Studio:  {}\n  Date:    {}\n  Sort:    {}\n  Cast:    {}\n  Poster:  {}\n\n{}",
        desired.title,
        desired.studio,
        desired.date,
        desired.title_sort,
        desired.cast.join(", "),
        desired.poster.as_deref().unwrap_or("none"),
        desired.summary
    );
    println!("\n{:.0} s, {} searches, {} pages, {} turns.", started.elapsed().as_secs_f64(), took.searches, took.reads, took.turns);
    Ok(())
}

/// Researches one file name with the configured model and search engine and prints the record and what Plex would
/// show, without writing anything.
async fn try_one(paths: &Paths, config: &Config, name: &str) -> Result<(), String> {
    let model = config.usable_model()?.ok_or("No model is set: crucible-server model --url")?;
    let engine = config.sports.engine.clone().ok_or("No search engine is set: crucible-server research --searxng <url>")?;
    if !config.sports.agreed_to_engine() {
        return Err("Agree to where searches go first: crucible-server research --agree".into());
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

/// When research runs, in a line: any time, or the schedule's hours and when it next starts or stops.
fn hours_line(config: &Config) -> String {
    let Some(week) = config.sports.schedule else { return "\nResearch runs at any time (set hours with --schedule).".into() };
    let clock = schedule::local_now();
    let zone = schedule::zone_name(&clock).unwrap_or_else(|| clock.offset().to_string());
    let next = week.next_change(&clock).map(|at| {
        let verb = if week.open_at(&clock) { "stops" } else { "starts" };
        format!(", {verb} {} at {:02}:00", day_name(at.weekday().to_monday_zero_offset()), at.hour())
    });
    format!("\nResearch runs {} ({} hours a week, {zone}){}.", week.spec(), week.hours(), next.unwrap_or_default())
}

fn day_name(monday_zero: i8) -> &'static str {
    ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][monday_zero.rem_euclid(7) as usize]
}
