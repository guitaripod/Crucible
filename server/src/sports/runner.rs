//! The sports service inside `serve`: it waits for the owner's libraries to gain files, researches one file at a time
//! on the owner's model, writes what it found into Plex, and keeps what it did so a file is researched once.

use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use futures_util::stream::{self, StreamExt};
use serde::Serialize;
use tokio::sync::Notify;

use super::apply::{apply, artwork_of, edited_by_owner, undo_pairs, Original};
use super::checks::{self, Check, Inputs};
use super::record::{days_from_civil, Desired, Record};
use super::release::Release;
use super::research::{research, ResearchError, Step};
use super::web::{Engine, Web};
use super::work::{research_work, Work, WorkRecord};
use crate::brain::Brain;
use crate::config::{Config, Kind, Model, Sports as Settings};
use crate::paths::Paths;
use crate::plex::{Artwork, Item, Plex, PlexError};
use crate::store::{now, SportsItem, Store, UNMEASURED};

/// How often the libraries are looked at when nothing wakes the service sooner.
const EVERY: Duration = Duration::from_secs(20 * 60);
/// How long research waits after the search engines turned it away before it looks again.
const SEARCH_PAUSE: i64 = 10 * 60;
/// How long checks are trusted before they run again on their own.
const CHECKS_KEPT: i64 = 10 * 60;

/// How handling one item ended, for the pass to decide whether to go on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Handled {
    Done,
    /// The search engine turned research away; the rest of the pass waits for the next one.
    SearchBusy,
    /// The owner took the item's library out, or switched research off, while it ran.
    Stopped,
}

/// A record research made: of a sports event, or of any other work.
enum Found {
    Event(Record),
    Work(WorkRecord),
}

impl Found {
    /// The record kept for an item, when it was researched as the kind its library holds now. A record from before
    /// the owner changed the library's kind is not read as the new kind's, so the file is researched again.
    fn read(kind: Kind, text: &str) -> Option<Found> {
        let value: serde_json::Value = serde_json::from_str(text).ok()?;
        let stored = value.get("kind").and_then(serde_json::Value::as_str).unwrap_or(Kind::Sports.name());
        if stored != kind.name() {
            return None;
        }
        match kind {
            Kind::Sports => serde_json::from_value::<Record>(value).ok().map(Found::Event),
            Kind::Adult | Kind::General => serde_json::from_value::<WorkRecord>(value).ok().map(Found::Work),
        }
    }

    fn settle(&mut self, release: &Release, work: &Work) {
        match self {
            Found::Event(record) => record.settle(release),
            Found::Work(record) => record.settle(work),
        }
    }

    fn render(&self, together: bool) -> Desired {
        match self {
            Found::Event(record) => record.render(together),
            Found::Work(record) => record.render(),
        }
    }

    /// The record as kept, marked with the kind it was researched as.
    fn json(&self, kind: Kind) -> Option<String> {
        let mut value = match self {
            Found::Event(record) => serde_json::to_value(record).ok()?,
            Found::Work(record) => serde_json::to_value(record).ok()?,
        };
        value.as_object_mut()?.insert("kind".into(), kind.name().into());
        serde_json::to_string(&value).ok()
    }
}

/// What the service is doing now, for the app.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// `idle`, `looking`, `researching`, `writing`, `waiting` (not everything is ready) or `paused` (the search engines
    /// turned research away; it goes on at `paused_until`).
    pub phase: String,
    /// When research looks again after the search engines turned it away.
    pub paused_until: Option<i64>,
    /// The search engines that turned research away, as people know them, when it is paused for them.
    pub limited: Vec<String>,
    /// Items still to take back after the owner undid a library's research.
    pub undoing: usize,
    /// The research running longest, for clients that show one.
    pub current: Option<Current>,
    /// Every research running now, oldest first.
    pub running: Vec<Current>,
    pub queued: usize,
    pub last_pass: Option<i64>,
    pub last_error: Option<String>,
}

/// The file being researched and the step the model is on.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Current {
    pub rating_key: String,
    pub name: String,
    pub file: String,
    /// What the file's library holds: `sports`, `adult` or `general`.
    pub kind: String,
    /// The step in words, for clients from before `steps`.
    pub step: String,
    pub started: i64,
    /// Seconds since the research of this file started, as the server counts them.
    pub elapsed: i64,
    /// The newest steps of this file's research, oldest first, for the live timeline.
    pub steps: Vec<LiveStep>,
}

/// One step of a live research: `thinking`, `searching` (detail: the query), `reading` (detail: the page),
/// `checking` or `writing`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveStep {
    /// Rises with every step of the server's life, so a client keys its timeline rows by it.
    pub id: u64,
    pub kind: String,
    pub detail: String,
    pub at: i64,
}

static STEP_IDS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Steps kept for the live timeline.
const STEPS_SHOWN: usize = 12;

impl Status {
    /// The live research of the item with `rating_key`, when it runs.
    fn live(&mut self, rating_key: &str) -> Option<&mut Current> {
        self.running.iter_mut().find(|current| current.rating_key == rating_key)
    }

    /// Shows `current` among the running research, in place of an earlier one of the same item.
    fn start(&mut self, current: Current) {
        self.finish(&current.rating_key);
        self.running.push(current);
    }

    fn finish(&mut self, rating_key: &str) {
        self.running.retain(|current| current.rating_key != rating_key);
    }
}

impl Current {
    /// The live research of `release`, starting now with no steps yet.
    fn starting(rating_key: &str, release: &Release) -> Self {
        Current::named(rating_key, &release.cleaned, &release.file_name, Kind::Sports)
    }

    /// The live research of a file by the name it is shown under and its file name, starting now with no steps yet.
    fn named(rating_key: &str, name: &str, file: &str, kind: Kind) -> Self {
        Current {
            rating_key: rating_key.to_string(),
            name: name.to_string(),
            file: file.to_string(),
            kind: kind.name().to_string(),
            step: "Thinking".into(),
            started: now(),
            elapsed: 0,
            steps: Vec::new(),
        }
    }

    /// Adds a step, folding a repeat of the step before it into that one so thinking between calls shows once.
    fn push(&mut self, kind: &str, detail: String) {
        self.step = match (kind, detail.is_empty()) {
            ("searching", false) => format!("Searching for {detail}"),
            ("reading", false) => format!("Reading {detail}"),
            ("checking", _) => "Checking the record".into(),
            ("writing", _) => "Writing to Plex".into(),
            _ => "Thinking".into(),
        };
        if self.steps.last().is_some_and(|last| last.kind == kind && last.detail == detail) {
            return;
        }
        let id = STEP_IDS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.steps.push(LiveStep { id, kind: kind.into(), detail, at: now() });
        if self.steps.len() > STEPS_SHOWN {
            self.steps.remove(0);
        }
    }
}

/// What researching a file took, or nothing when the research of another part of its event was reused.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Effort {
    pub seconds: i64,
    pub searches: i64,
    pub reads: i64,
}

pub struct Sports {
    paths: Paths,
    plex: Plex,
    store: Arc<Store>,
    owner_token: Option<String>,
    owner: String,
    model: Option<Model>,
    brain: Option<Brain>,
    settings: RwLock<Settings>,
    web: RwLock<Option<Web>>,
    status: Mutex<Status>,
    checked: Mutex<Option<(i64, Vec<Check>)>>,
    wake: Notify,
    /// Counts every change of the settings, so research running in a library the owner took out stops at once.
    changed: tokio::sync::watch::Sender<u64>,
    /// One lock per item, so research writing an item and the owner taking it back never run at once.
    item_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

/// The start of the note on an item whose research is done but whose write Plex refused.
const WRITE_REFUSED: &str = "Plex did not take the write";

/// Whether Crucible has already tried to write this item, so locks on it may be its own rather than the owner's.
fn wrote_before(known: Option<&SportsItem>) -> bool {
    known.is_some_and(|known| known.applied.is_some() || (known.state == "failed" && known.note.starts_with(WRITE_REFUSED)))
}

fn web_for(paths: &Paths, settings: &Settings) -> Option<Web> {
    let engine = settings.engine.clone()?;
    let key = matches!(engine, Engine::Brave).then(|| std::fs::read_to_string(paths.search_key()).ok()).flatten();
    Some(Web::new(engine, key))
}

/// How many events are researched at once: several on a model on the owner's own machines, which serves requests side by
/// side, and one at a time on a hosted model, which bills and rate-limits each request.
fn research_at_once(model: &Model) -> usize {
    match crate::net::model_place(&model.url) {
        crate::net::ModelPlace::Own => 4,
        crate::net::ModelPlace::Outside(_) => 1,
    }
}

/// A library item due for research, with the section it is in.
type Due<'a> = &'a (String, Item);

/// The due items in groups that run one after another, so a group's first research is there for the rest: the parts
/// of one sports event together, the copies and scenes of one work together, in the order they came; every other file
/// alone.
fn grouped<'a>(due: &[Due<'a>], kind_of: impl Fn(&str) -> Kind) -> Vec<Vec<Due<'a>>> {
    let mut groups: Vec<(Option<String>, Vec<Due<'a>>)> = Vec::new();
    for entry in due {
        let file = entry.1.part().and_then(|part| part.file.as_deref());
        let key = file.and_then(|file| match kind_of(&entry.0) {
            Kind::Sports => Release::read(file).event.map(|event| format!("event:{event}")),
            kind @ (Kind::Adult | Kind::General) => Some(format!("work:{}:{}", kind.name(), Work::read(file).key)),
        });
        match groups.iter_mut().find(|(group, _)| key.is_some() && *group == key) {
            Some((_, group)) => group.push(entry),
            None => groups.push((key, vec![entry])),
        }
    }
    groups.into_iter().map(|(_, group)| group).collect()
}

/// A day as YYYY-MM-DD and as days since 1970, from a Unix time.
fn day_of(seconds: i64) -> (String, i64) {
    let days = seconds.div_euclid(86_400);
    let mut year = 1970;
    while days_from_civil(year + 1, 1, 1) <= days {
        year += 1;
    }
    let mut month = 1;
    while month < 12 && days_from_civil(year, month + 1, 1) <= days {
        month += 1;
    }
    let day = days - days_from_civil(year, month, 1) + 1;
    (format!("{year:04}-{month:02}-{day:02}"), days)
}

impl Sports {
    pub fn new(paths: Paths, config: &Config, plex: Plex, store: Arc<Store>, owner_token: Option<String>) -> Self {
        let model = config.usable_model().ok().flatten().cloned();
        let brain = model.clone().map(|model| {
            let at_once = research_at_once(&model);
            Brain::with_stored_key(model, &paths).with_calls(at_once)
        });
        let web = web_for(&paths, &config.sports);
        Sports {
            plex,
            store,
            owner_token,
            owner: config.owner.clone(),
            model,
            brain,
            settings: RwLock::new(config.sports.clone()),
            web: RwLock::new(web),
            status: Mutex::new(Status { phase: "idle".into(), ..Status::default() }),
            checked: Mutex::new(None),
            wake: Notify::new(),
            changed: tokio::sync::watch::channel(0).0,
            item_locks: Mutex::new(HashMap::new()),
            paths,
        }
    }

    /// The model researching, by name and host, when one is set.
    pub fn model(&self) -> Option<(String, String)> {
        let model = self.model.as_ref()?;
        let host = reqwest::Url::parse(&model.url).ok().and_then(|url| url.host_str().map(str::to_string)).unwrap_or_default();
        Some((model.name.clone(), host))
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn status(&self) -> Status {
        let mut status = self.status.lock().unwrap_or_else(PoisonError::into_inner).clone();
        for current in &mut status.running {
            current.elapsed = (now() - current.started).max(0);
        }
        status.current = status.running.first().cloned();
        status
    }

    fn web(&self) -> Option<Web> {
        self.web.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn set_status(&self, change: impl FnOnce(&mut Status)) {
        change(&mut self.status.lock().unwrap_or_else(PoisonError::into_inner));
    }

    /// Changes the settings, keeps them in `config.toml`, checks again and looks at the libraries.
    pub fn update(&self, change: impl FnOnce(&mut Settings)) -> Result<Settings, String> {
        let mut config = Config::load(&self.paths.config()).map_err(|error| error.to_string())?;
        let mut updated = self.settings();
        change(&mut updated);
        config.sports = updated.clone();
        config.save(&self.paths.config()).map_err(|error| error.to_string())?;
        *self.settings.write().unwrap_or_else(PoisonError::into_inner) = updated.clone();
        *self.web.write().unwrap_or_else(PoisonError::into_inner) = web_for(&self.paths, &updated);
        *self.checked.lock().unwrap_or_else(PoisonError::into_inner) = None;
        self.changed.send_modify(|count| *count += 1);
        self.wake.notify_one();
        Ok(updated)
    }

    /// The lock that keeps research's write of an item and the owner's take back of it apart.
    fn item_lock(&self, rating_key: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.item_locks.lock().unwrap_or_else(PoisonError::into_inner).entry(rating_key.to_string()).or_default().clone()
    }

    /// Whether the owner took research back from an item, which is then left alone until they ask for it again.
    fn taken_back(&self, rating_key: &str) -> bool {
        self.store.sports_item(rating_key).ok().flatten().is_some_and(|row| row.state == "undone")
    }

    /// Whether research is off or the owner took `section` out of it.
    fn left_research(&self, section: &str) -> bool {
        let settings = self.settings();
        !settings.on || !settings.libraries.contains(&section.to_string())
    }

    /// Looks at the libraries now instead of at the next interval.
    pub fn wake(&self) {
        self.wake.notify_one();
    }

    /// The owner's libraries as (section key, title, is Other Videos), for choosing.
    pub async fn libraries(&self) -> Vec<(String, String, bool)> {
        self.listed_libraries().await.unwrap_or_default()
    }

    /// The owner's libraries as Plex lists them now, or why Plex could not list them.
    async fn listed_libraries(&self) -> Result<Vec<(String, String, bool)>, String> {
        let Some(token) = &self.owner_token else { return Ok(Vec::new()) };
        self.plex
            .sections(token)
            .await
            .map(|sections| sections.into_iter().map(|section| (section.key.clone(), section.title.clone(), section.is_other_videos())).collect())
            .map_err(|error| error.to_string())
    }

    /// Every requirement and where it stands, from the last ten minutes unless `again`.
    pub async fn checks(&self, again: bool) -> Vec<Check> {
        if !again {
            if let Some((at, checks)) = self.checked.lock().unwrap_or_else(PoisonError::into_inner).clone() {
                if now() - at < CHECKS_KEPT {
                    return checks;
                }
            }
        }
        let settings = self.settings();
        let web = self.web();
        let libraries = self.libraries().await;
        let checks = checks::run(Inputs {
            plex: &self.plex,
            owner_token: self.owner_token.as_deref(),
            owner: &self.owner,
            model: self.model.as_ref(),
            brain: self.brain.as_ref(),
            web: web.as_ref(),
            settings: &settings,
            library_titles: &libraries,
            store: &self.store,
            probe_again: again,
        })
        .await;
        *self.checked.lock().unwrap_or_else(PoisonError::into_inner) = Some((now(), checks.clone()));
        checks
    }

    /// Runs for as long as the server does.
    pub async fn run(self: Arc<Self>) {
        tokio::time::sleep(Duration::from_secs(15)).await;
        loop {
            if self.settings().on {
                self.pass().await;
            }
            let wait = self.status().paused_until.map_or(EVERY, |until| Duration::from_secs((until - now()).clamp(60, EVERY.as_secs() as i64) as u64));
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(wait) => {}
            }
        }
    }

    /// One look at the chosen libraries: research what is new, write what changed.
    pub async fn pass(&self) {
        self.set_status(|status| status.phase = "looking".into());
        let checks = self.checks(false).await;
        if !checks::ready(&checks) {
            self.set_status(|status| {
                status.phase = "waiting".into();
                status.queued = 0;
            });
            return;
        }
        let (Some(token), Some(brain), Some(web)) = (self.owner_token.clone(), self.brain.clone(), self.web()) else {
            self.set_status(|status| status.phase = "waiting".into());
            return;
        };
        let listed = match self.listed_libraries().await {
            Ok(listed) => listed,
            Err(error) => {
                tracing::warn!(%error, "could not list the libraries");
                self.set_status(|status| {
                    status.phase = "idle".into();
                    status.last_error = Some(error);
                });
                return;
            }
        };
        let titles: HashMap<String, String> = listed.iter().map(|(key, title, _)| (key.clone(), title.clone())).collect();
        let existing: Vec<String> = listed.into_iter().filter(|(_, _, other_videos)| *other_videos).map(|(key, _, _)| key).collect();
        let sections: Vec<String> = self.settings().libraries.into_iter().filter(|section| existing.contains(section)).collect();
        let mut items: Vec<(String, Item)> = Vec::new();
        for section in &sections {
            match self.plex.section_videos(section, &token).await {
                Ok(found) => items.extend(found.into_iter().map(|item| (section.clone(), item))),
                Err(error) => {
                    tracing::warn!(%section, %error, "could not list a sports library");
                    self.set_status(|status| {
                        status.phase = "idle".into();
                        status.last_error = Some(error.to_string());
                    });
                    return;
                }
            }
        }
        let present: Vec<String> = items.iter().map(|(_, item)| item.rating_key.clone()).collect();
        let _ = self.store.keep_sports_items(&sections, &present);
        let mut parts_per_event: HashMap<String, usize> = HashMap::new();
        for (_, item) in &items {
            if let Some(event) = item.part().and_then(|part| part.file.as_deref()).map(Release::read).and_then(|release| release.event) {
                *parts_per_event.entry(event).or_default() += 1;
            }
        }
        self.follow_owner_titles(&items);
        let mut due: Vec<&(String, Item)> = items.iter().filter(|(_, item)| self.is_due(item)).collect();
        due.sort_by_key(|(_, item)| std::cmp::Reverse(item.added_at.unwrap_or(0)));
        let kinds = self.settings();
        self.set_status(|status| {
            status.phase = if due.is_empty() { "idle" } else { "researching" }.into();
            status.queued = due.len();
        });
        let paused = AtomicBool::new(false);
        let started = AtomicUsize::new(0);
        stream::iter(grouped(&due, |section| kinds.kind_of(section)))
            .for_each_concurrent(research_at_once(&brain.model), |group| {
                let (brain, web, token, parts_per_event, paused, started, total, titles) =
                    (&brain, &web, &token, &parts_per_event, &paused, &started, due.len(), &titles);
                async move {
                    for (section, item) in group {
                        let settings = self.settings();
                        if paused.load(Ordering::Relaxed) || !settings.on || !settings.agreed_to_engine() {
                            return;
                        }
                        if !settings.libraries.contains(section) {
                            continue;
                        }
                        let begun = started.fetch_add(1, Ordering::Relaxed) + 1;
                        self.set_status(|status| status.queued = total.saturating_sub(begun));
                        let library = titles.get(section).map(String::as_str).unwrap_or("");
                        let handled = self.handle(brain, web, token, section, library, item, parts_per_event).await;
                        self.set_status(|status| status.finish(&item.rating_key));
                        if handled == Handled::SearchBusy {
                            paused.store(true, Ordering::Relaxed);
                            return;
                        }
                    }
                }
            })
            .await;
        let paused = paused.load(Ordering::Relaxed);
        self.set_status(|status| {
            status.running.clear();
            status.queued = 0;
            status.last_pass = Some(now());
            if paused {
                status.phase = "paused".into();
                status.paused_until = Some(now() + SEARCH_PAUSE);
            } else {
                status.phase = "idle".into();
                status.paused_until = None;
                status.limited.clear();
                status.last_error = None;
            }
        });
    }

    /// Keeps the title of each item the owner edited as Plex shows it now, since research leaves those items alone and
    /// would otherwise go on showing the title they had when the owner first changed them.
    fn follow_owner_titles(&self, items: &[(String, Item)]) {
        for (_, item) in items {
            let Some(mut known) = self.store.sports_item(&item.rating_key).ok().flatten() else { continue };
            if known.state == "edited" && !item.title.trim().is_empty() && known.title != item.title {
                known.title = item.title.clone();
                let _ = self.store.save_sports_item(&known);
            }
        }
    }

    /// Whether an item needs research or a fresh write: new, due for another try, or matched before its collection
    /// changed. An item the owner edited is theirs.
    fn is_due(&self, item: &Item) -> bool {
        match self.store.sports_item(&item.rating_key).ok().flatten() {
            None => true,
            Some(known) => match known.state.as_str() {
                "failed" | "attention" => known.next_try <= now(),
                "matched" => true,
                _ => false,
            },
        }
    }

    /// Resolves once the owner takes `section` out of research or switches research off.
    async fn stopped(&self, section: &str) {
        let mut changes = self.changed.subscribe();
        loop {
            if self.left_research(section) {
                return;
            }
            if changes.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn handle(
        &self,
        brain: &Brain,
        web: &Web,
        token: &str,
        section: &str,
        library: &str,
        item: &Item,
        parts_per_event: &HashMap<String, usize>,
    ) -> Handled {
        let Some(file) = item.part().and_then(|part| part.file.clone()) else { return Handled::Done };
        let kind = self.settings().kind_of(section);
        let release = Release::read(&file);
        let work = Work::read(&file);
        let shown_name = if kind == Kind::Sports { release.cleaned.clone() } else { work.cleaned.clone() };
        let lock = self.item_lock(&item.rating_key);
        let looking = lock.lock().await;
        let known = self.store.sports_item(&item.rating_key).ok().flatten();
        if known.as_ref().is_some_and(|known| known.state == "undone") {
            return Handled::Done;
        }
        let mut row = known.clone().unwrap_or_else(|| SportsItem {
            rating_key: item.rating_key.clone(),
            section: section.to_string(),
            file: file.clone(),
            state: "failed".into(),
            title: shown_name.clone(),
            record: None,
            applied: None,
            note: String::new(),
            tries: 0,
            next_try: 0,
            updated: now(),
            seconds: UNMEASURED,
            searches: UNMEASURED,
            reads: UNMEASURED,
            original: None,
        });
        let together = release.event.as_ref().and_then(|event| parts_per_event.get(event)).is_some_and(|count| *count > 1);
        let applied: Option<Desired> = row.applied.as_deref().and_then(|text| serde_json::from_str(text).ok());
        let wanted: Option<Desired> = row.record.as_deref().and_then(|text| Found::read(kind, text)).map(|found| found.render(together));
        let set_by_hand = match &applied {
            Some(applied) => edited_by_owner(item, applied) && wanted.as_ref().is_none_or(|wanted| edited_by_owner(item, wanted)),
            None => {
                !wrote_before(known.as_ref()) && item.locks.iter().any(|lock| lock.locked && matches!(lock.name.as_str(), "title" | "summary" | "titleSort"))
            }
        };
        if set_by_hand {
            row.state = "edited".into();
            if !item.title.trim().is_empty() {
                row.title = item.title.clone();
            }
            row.note = "You changed this in Plex, so it is left as you made it.".into();
            row.updated = now();
            let _ = self.store.save_sports_item(&row);
            return Handled::Done;
        }
        drop(looking);
        let stored = row.record.as_deref().and_then(|text| Found::read(kind, text));
        let researched = match (&known, stored) {
            (Some(known), Some(mut found)) if known.state == "matched" || wrote_before(Some(known)) => {
                found.settle(&release, &work);
                Ok((found, None))
            }
            _ => {
                let research = async {
                    match kind {
                        Kind::Sports => self.record_for(brain, web, item, &release).await.map(|(record, effort)| (Found::Event(record), Some(effort))),
                        Kind::Adult | Kind::General => {
                            self.work_for(brain, web, kind, item, &work, library).await.map(|(record, effort)| (Found::Work(record), Some(effort)))
                        }
                    }
                };
                tokio::select! {
                    researched = research => researched,
                    () = self.stopped(section) => return Handled::Stopped,
                }
            }
        };
        let _writing = lock.lock().await;
        if self.left_research(section) {
            return Handled::Stopped;
        }
        if self.taken_back(&item.rating_key) {
            return Handled::Done;
        }
        let found = match researched {
            Ok((found, effort)) => {
                if let Some(effort) = effort {
                    row.seconds = effort.seconds;
                    row.searches = effort.searches;
                    row.reads = effort.reads;
                }
                found
            }
            Err((state, note, wait)) => {
                let busy = note.starts_with("Searching paused");
                row.tries += if busy { 0 } else { 1 };
                row.state = state.into();
                row.note = note;
                row.next_try = now() + wait.saturating_mul(row.tries.clamp(1, 6));
                row.updated = now();
                let _ = self.store.save_sports_item(&row);
                return if busy { Handled::SearchBusy } else { Handled::Done };
            }
        };
        let desired = found.render(together);
        if known.as_ref().is_some_and(|known| known.state == "matched") && applied.as_ref() == Some(&desired) {
            return Handled::Done;
        }
        if row.original.is_none() && row.applied.is_none() {
            let mut before = self.plex.item(&item.rating_key, token).await.map(|full| Original::of(&full)).unwrap_or_else(|_| Original::of(item));
            before.poster = self.plex.chosen_artwork(&item.rating_key, Artwork::Poster, token).await.ok().flatten();
            before.background = self.plex.chosen_artwork(&item.rating_key, Artwork::Background, token).await.ok().flatten();
            row.original = serde_json::to_string(&before).ok();
            let _ = self.store.save_sports_item(&row);
        }
        self.set_status(|status| {
            status.phase = "writing".into();
            if status.live(&item.rating_key).is_none() {
                status.start(Current::named(&item.rating_key, &shown_name, &release.file_name, kind));
            }
            if let Some(current) = status.live(&item.rating_key) {
                current.push("writing", String::new());
            }
        });
        match apply(&self.plex, web, token, section, item, &desired, applied.as_ref()).await {
            Ok(outcome) => {
                let mut written = desired.clone();
                if !outcome.poster && desired.poster != applied.as_ref().and_then(|before| before.poster.clone()) {
                    written.poster = applied.as_ref().and_then(|before| before.poster.clone());
                }
                if !outcome.background && desired.background != applied.as_ref().and_then(|before| before.background.clone()) {
                    written.background = applied.as_ref().and_then(|before| before.background.clone());
                }
                row.state = "matched".into();
                row.title = desired.title.clone();
                row.record = found.json(kind);
                row.applied = serde_json::to_string(&written).ok();
                row.note = outcome.notes.join("; ");
                row.tries = 0;
                row.next_try = 0;
            }
            Err(error) => {
                row.tries += 1;
                row.state = "failed".into();
                row.record = found.json(kind);
                row.note = format!("{WRITE_REFUSED}: {error}");
                row.next_try = now() + 15 * 60 * row.tries.min(6);
            }
        }
        row.updated = now();
        let _ = self.store.save_sports_item(&row);
        self.set_status(|status| status.phase = "researching".into());
        Handled::Done
    }

    /// The record for a file that is not sports: from an earlier research of the same work (another copy, or another
    /// scene of the same movie), or a new one. On failure, the state, note and seconds to wait before trying again.
    async fn work_for(
        &self,
        brain: &Brain,
        web: &Web,
        kind: Kind,
        item: &Item,
        work: &Work,
        library: &str,
    ) -> Result<(WorkRecord, Effort), (&'static str, String, i64)> {
        let key = format!("work:{}:{}", kind.name(), work.key);
        if let Some(mut record) = self.store.sports_event(&key).ok().flatten().and_then(|(text, _)| serde_json::from_str::<WorkRecord>(&text).ok()) {
            record.settle(work);
            return Ok((record, Effort::default()));
        }
        let (added, newest) = day_of(item.added_at.unwrap_or_else(now));
        let started = now();
        self.set_status(|status| {
            status.phase = "researching".into();
            status.start(Current { started, ..Current::named(&item.rating_key, &work.cleaned, &work.file_name, kind) });
        });
        let on_step = |step: Step| self.show_step(&item.rating_key, step);
        match research_work(brain, web, kind, work, library, &added, newest + 1, &on_step).await {
            Ok((record, took)) if record.identified => {
                tracing::info!(file = %work.file_name, seconds = took.seconds, searches = took.searches, reads = took.reads, "researched a file");
                let mut shared = record.clone();
                shared.part = None;
                if let Ok(text) = serde_json::to_string(&shared) {
                    let _ = self.store.save_sports_event(&key, &text);
                }
                Ok((record, Effort { seconds: took.seconds as i64, searches: took.searches as i64, reads: took.reads as i64 }))
            }
            Ok((record, _)) if record.notes.starts_with(super::work::REFUSED) => Err(("attention", record.notes, 365 * 86_400)),
            Ok((record, _)) => Err(("attention", unidentified(&record.notes), 3 * 86_400)),
            Err(error) => Err(self.failed(error)),
        }
    }

    /// Shows one step of a running research on the item's live card.
    fn show_step(&self, rating_key: &str, step: Step) {
        let (kind, detail) = match step {
            Step::Thinking => ("thinking", String::new()),
            Step::Searching(query) => ("searching", query),
            Step::Reading(url) => ("reading", url.trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.").to_string()),
            Step::Checking => ("checking", String::new()),
        };
        self.set_status(|status| {
            if let Some(current) = status.live(rating_key) {
                current.push(kind, detail);
            }
        });
    }

    /// The state, note and wait for a research that did not end in a record.
    fn failed(&self, error: ResearchError) -> (&'static str, String, i64) {
        match error {
            ResearchError::NoRecord(problems) => ("attention", format!("The model's record did not pass the checks: {problems}"), 86_400),
            ResearchError::SearchBusy { reason, engines } => {
                self.set_status(|status| {
                    status.last_error = Some(reason.clone());
                    status.limited = engines;
                });
                ("failed", format!("Searching paused: {reason}"), 20 * 60)
            }
            ResearchError::Model(crate::brain::BrainError::Status(400, refusal)) => {
                ("attention", format!("The model refused the research, which usually means its context window is too small: {refusal}"), 86_400)
            }
            ResearchError::Model(error) => {
                self.set_status(|status| status.last_error = Some(error.to_string()));
                ("failed", format!("The model did not answer: {error}"), 15 * 60)
            }
        }
    }

    /// The record for a file: from an earlier research of the same event, or a new one. On failure, the state, note
    /// and seconds to wait before trying again.
    async fn record_for(&self, brain: &Brain, web: &Web, item: &Item, release: &Release) -> Result<(Record, Effort), (&'static str, String, i64)> {
        let cached = release
            .event
            .as_ref()
            .and_then(|event| self.store.sports_event(event).ok().flatten())
            .and_then(|(text, _)| serde_json::from_str::<Record>(&text).ok());
        if let Some(mut record) = cached.clone() {
            record.settle(release);
            if !record.lineup.iter().any(|bout| bout.part.is_some()) || !record.bouts_for(record.part.as_deref()).is_empty() {
                return Ok((record, Effort::default()));
            }
        }
        let (added, newest) = day_of(item.added_at.unwrap_or_else(now));
        let started = now();
        self.set_status(|status| {
            status.phase = "researching".into();
            status.start(Current { started, ..Current::starting(&item.rating_key, release) });
        });
        let on_step = |step: Step| self.show_step(&item.rating_key, step);
        match research(brain, web, release, &added, newest + 1, &on_step).await {
            Ok(done) if done.record.identified => {
                tracing::info!(file = %release.file_name, seconds = done.seconds, searches = done.searches, reads = done.reads, "researched a sports file");
                if let Some(event) = &release.event {
                    let mut shared = done.record.clone();
                    shared.part = None;
                    if let Some(earlier) = &cached {
                        for bout in &earlier.lineup {
                            if !shared.lineup.iter().any(|known| known.matchup.eq_ignore_ascii_case(&bout.matchup)) {
                                shared.lineup.push(bout.clone());
                            }
                        }
                        shared.lineup.sort_by_key(|bout| std::cmp::Reverse(super::release::part_order(bout.part.as_deref())));
                    }
                    if let Ok(text) = serde_json::to_string(&shared) {
                        let _ = self.store.save_sports_event(event, &text);
                    }
                }
                Ok((done.record, Effort { seconds: done.seconds as i64, searches: done.searches as i64, reads: done.reads as i64 }))
            }
            Ok(done) => Err(("attention", unidentified(&done.record.notes), 3 * 86_400)),
            Err(error) => Err(self.failed(error)),
        }
    }

    /// The items to show, newest first, and how many are in each state.
    pub fn items(&self, limit: usize) -> (Vec<SportsItem>, BTreeMap<String, i64>) {
        let chosen = self.settings().libraries;
        let items = self.store.sports_items_among(&chosen, limit).unwrap_or_default();
        let counts = self.store.sports_counts_among(&chosen).unwrap_or_default().into_iter().collect();
        (items, counts)
    }

    /// How many files research has written to or looked at, by library, so a library the owner took out can still be
    /// taken back.
    pub fn researched_per_library(&self) -> BTreeMap<String, i64> {
        self.store.sports_per_section().unwrap_or_default().into_iter().collect()
    }

    /// Takes research back from one item: every field research wrote and the owner did not change since returns to
    /// what Plex showed before and is unlocked, so Plex's own agent manages it again; the genres, collections and cast
    /// research added go, and its artwork gives way to the image Plex showed before. What the owner changed by hand
    /// stays as they made it. The item is not researched again until the owner asks.
    pub async fn undo(&self, rating_key: &str) -> Result<(), String> {
        let token = self.owner_token.as_deref().ok_or("Crucible Server is not signed in to Plex.")?;
        let lock = self.item_lock(rating_key);
        let _writing = lock.lock().await;
        let mut row = self.store.sports_item(rating_key).map_err(|error| error.to_string())?.ok_or("Research has nothing for that item.")?;
        let file_name = row.file.rsplit(['/', '\\']).next().unwrap_or(&row.file).to_string();
        let original: Original = row.original.as_deref().and_then(|text| serde_json::from_str(text).ok()).unwrap_or_else(|| Original::of_file(&file_name));
        let applied: Option<Desired> = row.applied.as_deref().and_then(|text| serde_json::from_str(text).ok());
        let mut shown = row.title.clone();
        if applied.is_some() || wrote_before(Some(&row)) {
            match self.plex.item(rating_key, token).await {
                Ok(now) => {
                    let pairs = undo_pairs(&original, applied.as_ref(), &now);
                    shown = if pairs.iter().any(|(name, _)| name == "title.value") { original.title.clone() } else { now.title.clone() };
                    if !pairs.is_empty() {
                        self.plex.edit(&row.section, rating_key, &pairs, token).await.map_err(|error| error.to_string())?;
                    }
                    let uploaded = |kind: Artwork| applied.as_ref().is_some_and(|applied| artwork_of(applied, kind).is_some());
                    for (kind, before) in [(Artwork::Poster, &original.poster), (Artwork::Background, &original.background)] {
                        if uploaded(kind) {
                            self.restore_artwork(&row.section, rating_key, kind, before.as_deref(), token).await;
                        }
                    }
                    if let Err(error) = self.plex.refresh_item(rating_key, token).await {
                        tracing::warn!(%error, rating_key, "Plex did not refresh an item research took back");
                    }
                }
                Err(PlexError::NotFound(_)) => tracing::info!(file = %file_name, "an item research took back is no longer in Plex"),
                Err(error) => return Err(error.to_string()),
            }
        }
        row.state = "undone".into();
        row.title = shown;
        row.record = None;
        row.applied = None;
        row.note = "Taken back: Plex shows the file as it did before research, with your own changes kept.".into();
        row.tries = 0;
        row.next_try = 0;
        row.updated = now();
        self.store.save_sports_item(&row).map_err(|error| error.to_string())?;
        tracing::info!(file = %file_name, "took research back");
        Ok(())
    }

    /// Shows the image Plex showed before research uploaded its own, unless the owner chose another one since: the
    /// one kept from before, or else the first image Plex made itself, or no image at all when Plex has made none, as
    /// before research. An image Plex made, or none, is unlocked again; one the owner uploaded before research stays
    /// locked.
    async fn restore_artwork(&self, section: &str, rating_key: &str, kind: Artwork, before: Option<&str>, token: &str) {
        let Ok(choices) = self.plex.artwork_choices(rating_key, kind, token).await else { return };
        let uploaded = |key: &str| key.starts_with("upload://");
        let shown = choices.iter().find(|choice| choice.selected);
        if shown.is_some_and(|choice| !uploaded(&choice.key)) {
            return;
        }
        let target = before
            .filter(|before| choices.iter().any(|choice| choice.key == *before))
            .or_else(|| choices.iter().map(|choice| choice.key.as_str()).find(|key| !uploaded(key)));
        let restored = match (target, shown) {
            (Some(target), _) => self.plex.choose_artwork(rating_key, kind, target, token).await.map(|()| !uploaded(target)),
            (None, Some(shown)) => self.plex.clear_artwork(rating_key, kind, &shown.key, token).await.map(|()| true),
            (None, None) => Ok(true),
        };
        match restored {
            Ok(true) => {
                let _ = self.plex.edit(section, rating_key, &[(kind.lock_field().to_string(), "0".to_string())], token).await;
            }
            Ok(false) => {}
            Err(error) => tracing::warn!(%error, rating_key, "Plex did not take back research's artwork"),
        }
    }

    /// Takes research back from every item of a library, one after another. A library the owner no longer chose is
    /// forgotten afterwards, so choosing it again starts afresh; one still chosen keeps its items as taken back.
    pub async fn undo_library(&self, section: &str) -> (usize, usize) {
        let rows: Vec<SportsItem> = self.store.sports_items_in(section).unwrap_or_default().into_iter().filter(|row| row.state != "undone").collect();
        self.set_status(|status| status.undoing += rows.len());
        let (mut undone, mut failed) = (0, 0);
        for row in &rows {
            match self.undo(&row.rating_key).await {
                Ok(()) => undone += 1,
                Err(error) => {
                    failed += 1;
                    tracing::warn!(%error, rating_key = %row.rating_key, "could not take research back");
                }
            }
            self.set_status(|status| status.undoing = status.undoing.saturating_sub(1));
        }
        if !self.settings().libraries.contains(&section.to_string()) && failed == 0 {
            let _ = self.store.forget_sports_section(section);
        }
        tracing::info!(section, undone, failed, "took research back from a library");
        (undone, failed)
    }

    /// Researches an item again from scratch, with its event.
    pub fn redo(&self, rating_key: &str) -> bool {
        let Some(known) = self.store.sports_item(rating_key).ok().flatten() else { return false };
        match self.settings().kind_of(&known.section) {
            Kind::Sports => {
                if let Some(event) = Release::read(&known.file).event {
                    let _ = self.store.forget_sports_event(&event);
                }
            }
            kind => {
                let _ = self.store.forget_sports_event(&format!("work:{}:{}", kind.name(), Work::read(&known.file).key));
            }
        }
        let mut cleared = known;
        cleared.state = "failed".into();
        cleared.record = None;
        cleared.next_try = 0;
        cleared.note = "Researching again.".into();
        cleared.seconds = UNMEASURED;
        cleared.searches = UNMEASURED;
        cleared.reads = UNMEASURED;
        cleared.updated = now();
        let _ = self.store.save_sports_item(&cleared);
        self.wake();
        true
    }
}

/// The note for a file the model could not identify: its reason when it gave one.
fn unidentified(notes: &str) -> String {
    match notes.trim().trim_end_matches('.') {
        "" => "The model could not identify it.".into(),
        reason => format!("The model could not identify it: {reason}."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(rating_key: &str, file: &str) -> (String, Item) {
        let json = serde_json::json!({"ratingKey": rating_key, "Media": [{"Part": [{"file": file}]}]});
        ("4".to_string(), serde_json::from_value(json).unwrap())
    }

    #[test]
    fn an_events_parts_stay_together_and_in_order_while_other_files_run_apart() {
        let items = [
            item("1", "/s/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"),
            item("2", "/s/Samourai.MMA.21.UFC.Fight.Pass.1080p.WEBRip.H264-Star.mp4"),
            item("3", "/s/UFC.334.PPV.Ciryl.Gane.vs.Josh.Hokit.1080p.HDTV.h264-Star.mp4"),
            item("4", "/s/CFFC 161 Lleshi vs Calvert UFC Fight Pass 1080p WEBRip H 264-Star.mp4"),
        ];
        let due: Vec<&(String, Item)> = items.iter().collect();
        let groups: Vec<Vec<&str>> =
            grouped(&due, |_| Kind::Sports).iter().map(|group| group.iter().map(|entry| entry.1.rating_key.as_str()).collect()).collect();
        assert_eq!(groups[0], vec!["1", "3"]);
        assert!(groups.iter().skip(1).all(|group| group.len() == 1));
        assert_eq!(groups.len(), 3);
    }

    #[test]
    fn running_research_is_listed_oldest_first_and_leaves_when_done() {
        let release = Release::read("/s/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4");
        let mut status = Status::default();
        status.start(Current::starting("1", &release));
        status.start(Current::starting("2", &release));
        status.live("2").unwrap().push("searching", "UFC 334 prelims".into());
        status.start(Current::starting("1", &release));
        assert_eq!(status.running.iter().map(|current| current.rating_key.as_str()).collect::<Vec<_>>(), vec!["2", "1"]);
        status.finish("2");
        assert_eq!(status.running.len(), 1);
        assert!(status.live("2").is_none());
    }

    #[test]
    fn a_hosted_model_researches_one_file_at_a_time() {
        let own = Model { url: "http://127.0.0.1:8081/v1".into(), name: "bolt".into(), context: 262_144 };
        assert_eq!(research_at_once(&own), 4);
        assert_eq!(research_at_once(&Model { url: "https://openrouter.ai/api/v1".into(), ..own }), 1);
    }

    #[test]
    fn an_unidentified_file_says_why_only_when_the_model_did() {
        assert_eq!(unidentified("  "), "The model could not identify it.");
        assert_eq!(unidentified("No page confirms the date."), "The model could not identify it: No page confirms the date.");
    }

    #[test]
    fn a_live_research_starts_with_the_file_and_no_steps() {
        let release = Release::read("/s/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4");
        let mut current = Current::starting("21417", &release);
        assert_eq!((current.rating_key.as_str(), current.file.as_str(), current.steps.len()), ("21417", "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4", 0));
        current.push("writing", String::new());
        current.push("writing", String::new());
        assert_eq!((current.step.as_str(), current.steps.len()), ("Writing to Plex", 1));
    }

    fn row(state: &str, note: &str, applied: Option<&str>) -> SportsItem {
        SportsItem {
            rating_key: "1".into(),
            section: "4".into(),
            file: "/mnt/Sports/UFC.334.mkv".into(),
            state: state.into(),
            title: "UFC 334".into(),
            record: None,
            applied: applied.map(str::to_string),
            note: note.into(),
            tries: 1,
            next_try: 0,
            updated: 0,
            seconds: UNMEASURED,
            searches: UNMEASURED,
            reads: UNMEASURED,
            original: None,
        }
    }

    #[test]
    fn only_rows_crucible_wrote_or_tried_to_write_can_own_their_locks() {
        assert!(!wrote_before(None));
        assert!(!wrote_before(Some(&row("attention", "Could not tell which event this is.", None))));
        assert!(!wrote_before(Some(&row("failed", "The model did not answer.", None))));
        assert!(wrote_before(Some(&row("failed", &format!("{WRITE_REFUSED}: 500"), None))));
        assert!(wrote_before(Some(&row("matched", "", Some("{}")))));
    }

    #[test]
    fn the_live_timeline_folds_repeats_and_keeps_the_newest_steps() {
        let mut current = Current::default();
        current.push("thinking", String::new());
        current.push("thinking", String::new());
        current.push("searching", "UFC 334 prelims".into());
        current.push("thinking", String::new());
        assert_eq!(current.steps.iter().map(|step| step.kind.as_str()).collect::<Vec<_>>(), ["thinking", "searching", "thinking"]);
        assert_eq!(current.step, "Thinking");
        current.push("reading", "ufc.com/event/ufc-334".into());
        assert_eq!(current.step, "Reading ufc.com/event/ufc-334");
        for page in 0..20 {
            current.push("reading", format!("page {page}"));
        }
        assert_eq!(current.steps.len(), STEPS_SHOWN);
        assert_eq!(current.steps.last().unwrap().detail, "page 19");
        assert!(current.steps.windows(2).all(|pair| pair[0].id < pair[1].id));
    }

    #[test]
    fn a_record_is_read_only_as_the_kind_it_was_researched_as() {
        let work = Found::Work(WorkRecord { identified: true, title: "The Deal".into(), ..WorkRecord::default() });
        let kept = work.json(Kind::General).unwrap();
        assert!(Found::read(Kind::General, &kept).is_some());
        assert!(Found::read(Kind::Adult, &kept).is_none() && Found::read(Kind::Sports, &kept).is_none());
        let from_before_kinds = r#"{"identified": true, "event": "UFC 334", "lineup": []}"#;
        assert!(Found::read(Kind::Adult, from_before_kinds).is_none());
    }

    #[test]
    fn copies_of_a_work_go_together_and_scenes_apart() {
        let items = [item("1", "/h/Movie X - sc1 720p.mp4"), item("2", "/h/Movie X - sc2 720p.mp4"), item("3", "/h/Movie X - sc1 1080p.mkv")];
        let due: Vec<&(String, Item)> = items.iter().collect();
        let groups: Vec<Vec<&str>> =
            grouped(&due, |_| Kind::Adult).iter().map(|group| group.iter().map(|entry| entry.1.rating_key.as_str()).collect()).collect();
        assert_eq!(groups, vec![vec!["1", "3"], vec!["2"]]);
    }

    #[test]
    fn reads_days_from_unix_time() {
        assert_eq!(day_of(0), ("1970-01-01".into(), 0));
        assert_eq!(day_of(1_794_736_125), ("2026-11-15".into(), days_from_civil(2026, 11, 15)));
        assert_eq!(day_of(951_782_400).0, "2000-02-29");
    }
}
