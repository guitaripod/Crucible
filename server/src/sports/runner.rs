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
use crate::store::{now, SportsItem, Store};

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
    pub step: String,
    pub started: i64,
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

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).clone()
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
        let Some(token) = &self.owner_token else { return Vec::new() };
        self.plex
            .sections(token)
            .await
            .map(|sections| sections.into_iter().map(|section| (section.key.clone(), section.title.clone(), section.is_other_videos())).collect())
            .unwrap_or_default()
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
        let existing: Vec<String> = self.libraries().await.into_iter().filter(|(_, _, other_videos)| *other_videos).map(|(key, _, _)| key).collect();
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
        });
        let applied: Option<Desired> = row.applied.as_deref().and_then(|text| serde_json::from_str(text).ok());
        let wanted: Option<Desired> = row.record.as_deref().and_then(|text| serde_json::from_str::<Record>(text).ok()).map(|record| {
            let together = release.event.as_ref().and_then(|event| parts_per_event.get(event)).is_some_and(|count| *count > 1);
            record.render(together)
        });
        let set_by_hand = match &applied {
            Some(applied) => edited_by_owner(item, applied) && wanted.as_ref().is_none_or(|wanted| edited_by_owner(item, wanted)),
            None => known.is_none() && item.locks.iter().any(|lock| lock.locked && matches!(lock.name.as_str(), "title" | "summary" | "titleSort")),
        };
        if set_by_hand {
            row.state = "edited".into();
            row.note = "You changed this in Plex, so it is left as you made it.".into();
            row.updated = now();
            let _ = self.store.save_sports_item(&row);
            return Handled::Done;
        }
        let record = match (&known, row.record.as_deref().and_then(|text| serde_json::from_str::<Record>(text).ok())) {
            (Some(known), Some(record)) if known.state == "matched" => record,
            _ => match self.record_for(brain, web, item, &release).await {
                Ok(record) => record,
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
            if let Some(current) = &mut status.current {
                current.step = "Writing to Plex".into();
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
                row.note = format!("Plex did not take the write: {error}");
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
    async fn record_for(&self, brain: &Brain, web: &Web, item: &Item, release: &Release) -> Result<Record, (&'static str, String, i64)> {
        let cached = release
            .event
            .as_ref()
            .and_then(|event| self.store.sports_event(event).ok().flatten())
            .and_then(|(text, _)| serde_json::from_str::<Record>(&text).ok());
        if let Some(mut record) = cached.clone() {
            record.settle(release);
            if !record.lineup.iter().any(|bout| bout.part.is_some()) || !record.bouts_for(record.part.as_deref()).is_empty() {
                return Ok(record);
            }
        }
        let (added, newest) = day_of(item.added_at.unwrap_or_else(now));
        let started = now();
        self.set_status(|status| {
            status.phase = "researching".into();
            status.current = Some(Current { rating_key: item.rating_key.clone(), name: release.cleaned.clone(), step: "Thinking".into(), started });
        });
        let on_step = |step: Step| {
            let words = match step {
                Step::Thinking => "Thinking".to_string(),
                Step::Searching(query) => format!("Searching for {query}"),
                Step::Reading(url) => format!("Reading {}", url.trim_start_matches("https://").trim_start_matches("http://").trim_start_matches("www.")),
                Step::Checking => "Checking the record".to_string(),
            };
            self.set_status(|status| {
                if let Some(current) = &mut status.current {
                    current.step = words;
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
                Ok(done.record)
            }
            Ok(done) => Err(("attention", format!("The model could not identify it: {}", done.record.notes.trim()), 3 * 86_400)),
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
        cleared.updated = now();
        let _ = self.store.save_sports_item(&cleared);
        self.wake();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_days_from_unix_time() {
        assert_eq!(day_of(0), ("1970-01-01".into(), 0));
        assert_eq!(day_of(1_794_736_125), ("2026-11-15".into(), days_from_civil(2026, 11, 15)));
        assert_eq!(day_of(951_782_400).0, "2000-02-29");
    }
}
