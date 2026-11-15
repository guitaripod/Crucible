//! The sports service inside `serve`: it waits for the owner's libraries to gain files, researches one file at a time
//! on the owner's model, writes what it found into Plex, and keeps what it did so a file is researched once.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::Duration;

use serde::Serialize;
use tokio::sync::Notify;

use super::apply::{apply, edited_by_owner};
use super::checks::{self, Check, Inputs};
use super::record::{days_from_civil, Desired, Record};
use super::release::Release;
use super::research::{research, ResearchError, Step};
use super::web::{Engine, Web};
use crate::brain::Brain;
use crate::config::{Config, Model, Sports as Settings};
use crate::paths::Paths;
use crate::plex::{Item, Plex};
use crate::store::{now, SportsItem, Store, UNMEASURED};

/// How often the libraries are looked at when nothing wakes the service sooner.
const EVERY: Duration = Duration::from_secs(20 * 60);
/// How long checks are trusted before they run again on their own.
const CHECKS_KEPT: i64 = 10 * 60;

/// How handling one item ended, for the pass to decide whether to go on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Handled {
    Done,
    /// The search engine turned research away; the rest of the pass waits for the next one.
    SearchBusy,
}

/// What the service is doing now, for the app.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// `idle`, `looking`, `researching`, `writing` or `waiting` (not everything is ready).
    pub phase: String,
    pub current: Option<Current>,
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

impl Current {
    /// The live research of `release`, starting now with no steps yet.
    fn starting(rating_key: &str, release: &Release) -> Self {
        Current {
            rating_key: rating_key.to_string(),
            name: release.cleaned.clone(),
            file: release.file_name.clone(),
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
        let brain = model.clone().map(|model| Brain::with_stored_key(model, &paths));
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
        if let Some(current) = &mut status.current {
            current.elapsed = (now() - current.started).max(0);
        }
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
        self.wake.notify_one();
        Ok(updated)
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
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(EVERY) => {}
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
        let existing: Vec<String> = listed.into_iter().filter(|(_, _, other_videos)| *other_videos).map(|(key, _, _)| key).collect();
        let mut items: Vec<(String, Item)> = Vec::new();
        for section in self.settings().libraries.into_iter().filter(|section| existing.contains(section)) {
            match self.plex.section_videos(&section, &token).await {
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
        let _ = self.store.keep_sports_items(&present);
        let mut parts_per_event: HashMap<String, usize> = HashMap::new();
        for (_, item) in &items {
            if let Some(event) = item.part().and_then(|part| part.file.as_deref()).map(Release::read).and_then(|release| release.event) {
                *parts_per_event.entry(event).or_default() += 1;
            }
        }
        self.follow_owner_titles(&items);
        let due: Vec<&(String, Item)> = items.iter().filter(|(_, item)| self.is_due(item)).collect();
        self.set_status(|status| {
            status.phase = if due.is_empty() { "idle" } else { "researching" }.into();
            status.queued = due.len();
        });
        let mut paused = false;
        for (index, (section, item)) in due.iter().enumerate() {
            let settings = self.settings();
            if !settings.on || !settings.agreed_to_engine() {
                break;
            }
            self.set_status(|status| status.queued = due.len() - index - 1);
            if self.handle(&brain, &web, &token, section, item, &parts_per_event).await == Handled::SearchBusy {
                paused = true;
                break;
            }
        }
        self.set_status(|status| {
            status.phase = "idle".into();
            status.current = None;
            status.queued = 0;
            status.last_pass = Some(now());
            if !paused {
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

    async fn handle(&self, brain: &Brain, web: &Web, token: &str, section: &str, item: &Item, parts_per_event: &HashMap<String, usize>) -> Handled {
        let Some(file) = item.part().and_then(|part| part.file.clone()) else { return Handled::Done };
        let release = Release::read(&file);
        let known = self.store.sports_item(&item.rating_key).ok().flatten();
        let mut row = known.clone().unwrap_or_else(|| SportsItem {
            rating_key: item.rating_key.clone(),
            section: section.to_string(),
            file: file.clone(),
            state: "failed".into(),
            title: release.cleaned.clone(),
            record: None,
            applied: None,
            note: String::new(),
            tries: 0,
            next_try: 0,
            updated: now(),
            seconds: UNMEASURED,
            searches: UNMEASURED,
            reads: UNMEASURED,
        });
        let applied: Option<Desired> = row.applied.as_deref().and_then(|text| serde_json::from_str(text).ok());
        let wanted: Option<Desired> = row.record.as_deref().and_then(|text| serde_json::from_str::<Record>(text).ok()).map(|record| {
            let together = release.event.as_ref().and_then(|event| parts_per_event.get(event)).is_some_and(|count| *count > 1);
            record.render(together)
        });
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
        let record = match (&known, row.record.as_deref().and_then(|text| serde_json::from_str::<Record>(text).ok())) {
            (Some(known), Some(record)) if known.state == "matched" || wrote_before(Some(known)) => record,
            _ => match self.record_for(brain, web, item, &release).await {
                Ok((record, effort)) => {
                    row.seconds = effort.seconds;
                    row.searches = effort.searches;
                    row.reads = effort.reads;
                    record
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
            },
        };
        let together = release.event.as_ref().and_then(|event| parts_per_event.get(event)).is_some_and(|count| *count > 1);
        let desired = record.render(together);
        if known.as_ref().is_some_and(|known| known.state == "matched") && applied.as_ref() == Some(&desired) {
            return Handled::Done;
        }
        self.set_status(|status| {
            status.phase = "writing".into();
            if status.current.as_ref().is_none_or(|current| current.rating_key != item.rating_key) {
                status.current = Some(Current::starting(&item.rating_key, &release));
            }
            if let Some(current) = &mut status.current {
                current.push("writing", String::new());
            }
        });
        match apply(&self.plex, web, token, section, &item.rating_key, &desired, applied.as_ref()).await {
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
                row.record = serde_json::to_string(&record).ok();
                row.applied = serde_json::to_string(&written).ok();
                row.note = outcome.notes.join("; ");
                row.tries = 0;
                row.next_try = 0;
            }
            Err(error) => {
                row.tries += 1;
                row.state = "failed".into();
                row.record = serde_json::to_string(&record).ok();
                row.note = format!("{WRITE_REFUSED}: {error}");
                row.next_try = now() + 15 * 60 * row.tries.min(6);
            }
        }
        row.updated = now();
        let _ = self.store.save_sports_item(&row);
        self.set_status(|status| status.phase = "researching".into());
        Handled::Done
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
            status.current = Some(Current { started, ..Current::starting(&item.rating_key, release) });
        });
        let on_step = |step: Step| {
            let (kind, detail) = match step {
                Step::Thinking => ("thinking", String::new()),
                Step::Searching(query) => ("searching", query),
                Step::Reading(url) => ("reading", url.trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.").to_string()),
                Step::Checking => ("checking", String::new()),
            };
            self.set_status(|status| {
                if let Some(current) = &mut status.current {
                    current.push(kind, detail);
                }
            });
        };
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
            Err(ResearchError::NoRecord(problems)) => Err(("attention", format!("The model's record did not pass the checks: {problems}"), 86_400)),
            Err(ResearchError::SearchBusy(reason)) => {
                self.set_status(|status| status.last_error = Some(reason.clone()));
                Err(("failed", format!("Searching paused: {reason}"), 20 * 60))
            }
            Err(ResearchError::Model(crate::brain::BrainError::Status(400, refusal))) => {
                Err(("attention", format!("The model refused the research, which usually means its context window is too small: {refusal}"), 86_400))
            }
            Err(ResearchError::Model(error)) => {
                self.set_status(|status| status.last_error = Some(error.to_string()));
                Err(("failed", format!("The model did not answer: {error}"), 15 * 60))
            }
        }
    }

    /// The items to show, newest first, and how many are in each state.
    pub fn items(&self, limit: usize) -> (Vec<SportsItem>, BTreeMap<String, i64>) {
        let items = self.store.sports_items(limit).unwrap_or_default();
        let counts = self.store.sports_counts().unwrap_or_default().into_iter().collect();
        (items, counts)
    }

    /// Researches an item again from scratch, with its event.
    pub fn redo(&self, rating_key: &str) -> bool {
        let Some(known) = self.store.sports_item(rating_key).ok().flatten() else { return false };
        if let Some(event) = Release::read(&known.file).event {
            let _ = self.store.forget_sports_event(&event);
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
    fn reads_days_from_unix_time() {
        assert_eq!(day_of(0), ("1970-01-01".into(), 0));
        assert_eq!(day_of(1_794_736_125), ("2026-11-15".into(), days_from_civil(2026, 11, 15)));
        assert_eq!(day_of(951_782_400).0, "2000-02-29");
    }
}
