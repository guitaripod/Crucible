//! The server's database: paired devices (their tokens only as hashes) and the summaries it has written.

use std::path::Path;
use std::sync::{Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use sha2::{Digest, Sha256};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS pending_pairings (
    id TEXT PRIMARY KEY,
    secret TEXT NOT NULL,
    expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sports_items (
    rating_key TEXT PRIMARY KEY,
    section TEXT NOT NULL,
    file TEXT NOT NULL,
    state TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    record TEXT,
    applied TEXT,
    note TEXT NOT NULL DEFAULT '',
    tries INTEGER NOT NULL DEFAULT 0,
    next_try INTEGER NOT NULL DEFAULT 0,
    updated INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sports_events (
    key TEXT PRIMARY KEY,
    record TEXT NOT NULL,
    researched INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS model_abilities (
    model TEXT PRIMARY KEY,
    tools INTEGER NOT NULL,
    thinking INTEGER NOT NULL,
    checked INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS summaries (
    rating_key TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    text TEXT NOT NULL,
    grounded INTEGER NOT NULL,
    created INTEGER NOT NULL,
    PRIMARY KEY (rating_key, source_hash, model, prompt_version)
);
";

/// A device as the owner sees it in `crucible-server devices` and the app's owner screen.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub created: i64,
    pub last_seen: i64,
}

/// A summary kept for an episode, valid while its dialogue, model and prompt are the same.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    pub text: String,
    pub grounded: bool,
}

pub struct Store {
    connection: Mutex<Connection>,
}

/// What the sports research made of one library item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SportsItem {
    pub rating_key: String,
    pub section: String,
    pub file: String,
    /// `matched`, `attention` (the model could not identify it, or its record failed the checks), `edited` (the owner
    /// changed what was written, so it is left alone), `failed` (the model, the web or Plex did not answer; tried again
    /// later) or `undone` (the owner took research back: Plex shows the file as it was, and it is not researched again
    /// until the owner asks).
    pub state: String,
    pub title: String,
    #[serde(skip)]
    pub record: Option<String>,
    #[serde(skip)]
    pub applied: Option<String>,
    pub note: String,
    pub tries: i64,
    pub next_try: i64,
    pub updated: i64,
    /// What the research of this file took; all zero when it reused the research of another part of the same event.
    pub seconds: i64,
    pub searches: i64,
    pub reads: i64,
    /// What Plex showed for the file before research first wrote to it, as JSON, so the owner can take research back.
    #[serde(skip)]
    pub original: Option<String>,
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// How a device token is kept: its SHA-256, so the database never holds a working token.
pub fn hash_token(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        Self::with(Connection::open(path)?)
    }

    pub fn in_memory() -> rusqlite::Result<Self> {
        Self::with(Connection::open_in_memory()?)
    }

    fn with(connection: Connection) -> rusqlite::Result<Self> {
        connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")?;
        connection.execute_batch(SCHEMA)?;
        if let Err(error) = connection.execute("ALTER TABLE sports_items ADD COLUMN original TEXT", []) {
            if !error.to_string().contains("duplicate column") {
                return Err(error);
            }
        }
        for column in ["seconds", "searches", "reads"] {
            let added = connection.execute(&format!("ALTER TABLE sports_items ADD COLUMN {column} INTEGER NOT NULL DEFAULT {UNMEASURED}"), []);
            if let Err(error) = added {
                if !error.to_string().contains("duplicate column") {
                    return Err(error);
                }
            }
        }
        Ok(Store { connection: Mutex::new(connection) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Records a newly paired device and returns its id.
    pub fn add_device(&self, name: &str, platform: &str, token: &str) -> rusqlite::Result<String> {
        let id = uuid::Uuid::new_v4().to_string();
        let at = now();
        self.lock().execute(
            "INSERT INTO devices (id, name, platform, token_hash, created, last_seen) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            params![id, name, platform, hash_token(token), at],
        )?;
        Ok(id)
    }

    /// The device a bearer token belongs to, marking it seen.
    pub fn device_for_token(&self, token: &str) -> rusqlite::Result<Option<Device>> {
        let connection = self.lock();
        let hash = hash_token(token);
        let device = connection
            .query_row("SELECT id, name, platform, created, last_seen FROM devices WHERE token_hash = ?1", params![hash], |row| {
                Ok(Device { id: row.get(0)?, name: row.get(1)?, platform: row.get(2)?, created: row.get(3)?, last_seen: row.get(4)? })
            })
            .optional()?;
        if device.is_some() {
            connection.execute("UPDATE devices SET last_seen = ?1 WHERE token_hash = ?2", params![now(), hash])?;
        }
        Ok(device)
    }

    pub fn devices(&self) -> rusqlite::Result<Vec<Device>> {
        let connection = self.lock();
        let mut statement = connection.prepare("SELECT id, name, platform, created, last_seen FROM devices ORDER BY created")?;
        let rows = statement
            .query_map([], |row| Ok(Device { id: row.get(0)?, name: row.get(1)?, platform: row.get(2)?, created: row.get(3)?, last_seen: row.get(4)? }))?;
        rows.collect()
    }

    /// Unpairs a device; returns whether there was one.
    pub fn remove_device(&self, id: &str) -> rusqlite::Result<bool> {
        Ok(self.lock().execute("DELETE FROM devices WHERE id = ?1", params![id])? > 0)
    }

    /// Unpairs every device, as a new certificate does.
    pub fn remove_all_devices(&self) -> rusqlite::Result<usize> {
        self.lock().execute("DELETE FROM devices", [])
    }

    /// Leaves a secret the terminal shows for the running server to pick up; it expires on its own, and its row stays a
    /// day longer so a paired device cannot hand it on as its own.
    pub fn add_pending_pairing(&self, id: &str, secret: &[u8; 16], expires: i64) -> rusqlite::Result<()> {
        let connection = self.lock();
        connection.execute("DELETE FROM pending_pairings WHERE expires <= ?1", params![now() - 86_400])?;
        connection.execute("INSERT OR REPLACE INTO pending_pairings (id, secret, expires) VALUES (?1, ?2, ?3)", params![id, hex::encode(secret), expires])?;
        Ok(())
    }

    /// Whether the terminal ever showed this secret and it has not been taken, expired or not.
    pub fn has_pending_pairing(&self, id: &str) -> rusqlite::Result<bool> {
        self.lock().query_row("SELECT 1 FROM pending_pairings WHERE id = ?1", params![id], |_| Ok(())).optional().map(|found| found.is_some())
    }

    /// Takes a secret the terminal showed out of the database, expired or not, with when it expires.
    pub fn take_pending_pairing(&self, id: &str) -> rusqlite::Result<Option<([u8; 16], i64)>> {
        let connection = self.lock();
        let found: Option<(String, i64)> =
            connection.query_row("SELECT secret, expires FROM pending_pairings WHERE id = ?1", params![id], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
        connection.execute("DELETE FROM pending_pairings WHERE id = ?1", params![id])?;
        Ok(found.and_then(|(secret, expires)| hex::decode(secret).ok()?.try_into().ok().map(|secret| (secret, expires))))
    }

    pub fn sports_item(&self, rating_key: &str) -> rusqlite::Result<Option<SportsItem>> {
        self.lock().query_row(&format!("SELECT {SPORTS_COLUMNS} FROM sports_items WHERE rating_key = ?1"), params![rating_key], sports_item_from).optional()
    }

    pub fn save_sports_item(&self, item: &SportsItem) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT OR REPLACE INTO sports_items (rating_key, section, file, state, title, record, applied, note, tries, next_try, updated, seconds, searches, reads, original)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                item.rating_key,
                item.section,
                item.file,
                item.state,
                item.title,
                item.record,
                item.applied,
                item.note,
                item.tries,
                item.next_try,
                item.updated,
                item.seconds,
                item.searches,
                item.reads,
                item.original
            ],
        )?;
        Ok(())
    }

    /// The most recently changed items, newest first.
    pub fn sports_items(&self, limit: usize) -> rusqlite::Result<Vec<SportsItem>> {
        let connection = self.lock();
        let mut statement = connection.prepare(&format!(
            "SELECT {SPORTS_COLUMNS} FROM sports_items ORDER BY CASE state WHEN 'attention' THEN 0 WHEN 'failed' THEN 1 ELSE 2 END, updated DESC, rating_key LIMIT ?1"
        ))?;
        let rows = statement.query_map(params![limit as i64], sports_item_from)?;
        rows.collect()
    }

    /// How many items are in each state.
    /// How many files research has a row for, by library section.
    pub fn sports_per_section(&self) -> rusqlite::Result<Vec<(String, i64)>> {
        let connection = self.lock();
        let mut statement = connection.prepare("SELECT section, COUNT(*) FROM sports_items WHERE state != 'undone' GROUP BY section")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect()
    }

    /// The items of the chosen sections to show: those needing a look first, then the most recently changed.
    pub fn sports_items_among(&self, sections: &[String], limit: usize) -> rusqlite::Result<Vec<SportsItem>> {
        if sections.is_empty() {
            return Ok(Vec::new());
        }
        let connection = self.lock();
        let marks = vec!["?"; sections.len()].join(", ");
        let mut statement = connection.prepare(&format!(
            "SELECT {SPORTS_COLUMNS} FROM sports_items WHERE section IN ({marks}) ORDER BY CASE state WHEN 'attention' THEN 0 WHEN 'failed' THEN 1 ELSE 2 END, updated DESC, rating_key LIMIT {limit}"
        ))?;
        let rows = statement.query_map(rusqlite::params_from_iter(sections.iter()), sports_item_from)?;
        rows.collect()
    }

    /// How many items of the chosen sections are in each state.
    pub fn sports_counts_among(&self, sections: &[String]) -> rusqlite::Result<Vec<(String, i64)>> {
        if sections.is_empty() {
            return Ok(Vec::new());
        }
        let connection = self.lock();
        let marks = vec!["?"; sections.len()].join(", ");
        let mut statement =
            connection.prepare(&format!("SELECT state, COUNT(*) FROM sports_items WHERE section IN ({marks}) GROUP BY state ORDER BY state"))?;
        let rows = statement.query_map(rusqlite::params_from_iter(sections.iter()), |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect()
    }

    /// The item whose rating key is `name`, or whose file is named `name`.
    pub fn sports_item_named(&self, name: &str) -> rusqlite::Result<Option<SportsItem>> {
        if let Some(item) = self.sports_item(name)? {
            return Ok(Some(item));
        }
        let connection = self.lock();
        let mut statement = connection.prepare(&format!("SELECT {SPORTS_COLUMNS} FROM sports_items WHERE file = ?1 OR file LIKE ?2 ESCAPE '\\' LIMIT 1"))?;
        let escaped = name.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
        statement.query_row(params![name, format!("%/{escaped}")], sports_item_from).optional()
    }

    /// Forgets every item of a library section.
    pub fn forget_sports_section(&self, section: &str) -> rusqlite::Result<usize> {
        self.lock().execute("DELETE FROM sports_items WHERE section = ?1", params![section])
    }

    /// Every item of one library section.
    pub fn sports_items_in(&self, section: &str) -> rusqlite::Result<Vec<SportsItem>> {
        let connection = self.lock();
        let mut statement = connection.prepare(&format!("SELECT {SPORTS_COLUMNS} FROM sports_items WHERE section = ?1"))?;
        let rows = statement.query_map(params![section], sports_item_from)?;
        rows.collect()
    }

    pub fn sports_counts(&self) -> rusqlite::Result<Vec<(String, i64)>> {
        let connection = self.lock();
        let mut statement = connection.prepare("SELECT state, COUNT(*) FROM sports_items GROUP BY state ORDER BY state")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect()
    }

    /// Forgets an item, so the research looks at it afresh; returns whether there was one.
    pub fn forget_sports_item(&self, rating_key: &str) -> rusqlite::Result<bool> {
        Ok(self.lock().execute("DELETE FROM sports_items WHERE rating_key = ?1", params![rating_key])? > 0)
    }

    /// Forgets items no longer in the library.
    pub fn keep_sports_items(&self, sections: &[String], present: &[String]) -> rusqlite::Result<usize> {
        let connection = self.lock();
        let known: Vec<(String, String)> = {
            let mut statement = connection.prepare("SELECT rating_key, section FROM sports_items")?;
            let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        let mut removed = 0;
        for (key, _) in known.iter().filter(|(key, section)| sections.contains(section) && !present.contains(key)) {
            removed += connection.execute("DELETE FROM sports_items WHERE rating_key = ?1", params![key])?;
        }
        Ok(removed)
    }

    pub fn sports_event(&self, key: &str) -> rusqlite::Result<Option<(String, i64)>> {
        self.lock().query_row("SELECT record, researched FROM sports_events WHERE key = ?1", params![key], |row| Ok((row.get(0)?, row.get(1)?))).optional()
    }

    pub fn save_sports_event(&self, key: &str, record: &str) -> rusqlite::Result<()> {
        self.lock().execute("INSERT OR REPLACE INTO sports_events (key, record, researched) VALUES (?1, ?2, ?3)", params![key, record, now()])?;
        Ok(())
    }

    pub fn forget_sports_event(&self, key: &str) -> rusqlite::Result<()> {
        self.lock().execute("DELETE FROM sports_events WHERE key = ?1", params![key])?;
        Ok(())
    }

    /// What a model showed it can do when last probed, with when.
    pub fn abilities(&self, model: &str) -> rusqlite::Result<Option<(bool, bool, i64)>> {
        self.lock()
            .query_row("SELECT tools, thinking, checked FROM model_abilities WHERE model = ?1", params![model], |row| {
                Ok((row.get::<_, i64>(0)? != 0, row.get::<_, i64>(1)? != 0, row.get(2)?))
            })
            .optional()
    }

    pub fn save_abilities(&self, model: &str, tools: bool, thinking: bool) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT OR REPLACE INTO model_abilities (model, tools, thinking, checked) VALUES (?1, ?2, ?3, ?4)",
            params![model, tools as i64, thinking as i64, now()],
        )?;
        Ok(())
    }

    pub fn summary(&self, rating_key: &str, source_hash: &str, model: &str, prompt_version: i64) -> rusqlite::Result<Option<Summary>> {
        self.lock()
            .query_row(
                "SELECT text, grounded FROM summaries WHERE rating_key = ?1 AND source_hash = ?2 AND model = ?3 AND prompt_version = ?4",
                params![rating_key, source_hash, model, prompt_version],
                |row| Ok(Summary { text: row.get(0)?, grounded: row.get::<_, i64>(1)? != 0 }),
            )
            .optional()
    }

    pub fn save_summary(&self, rating_key: &str, source_hash: &str, model: &str, prompt_version: i64, summary: &Summary) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT OR REPLACE INTO summaries (rating_key, source_hash, model, prompt_version, text, grounded, created) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![rating_key, source_hash, model, prompt_version, summary.text, summary.grounded as i64, now()],
        )?;
        Ok(())
    }
}

/// What a file researched before the server counted its effort holds in `seconds`, `searches` and `reads`: unknown, not none.
pub const UNMEASURED: i64 = -1;

const SPORTS_COLUMNS: &str = "rating_key, section, file, state, title, record, applied, note, tries, next_try, updated, seconds, searches, reads, original";

fn sports_item_from(row: &rusqlite::Row<'_>) -> rusqlite::Result<SportsItem> {
    Ok(SportsItem {
        rating_key: row.get(0)?,
        section: row.get(1)?,
        file: row.get(2)?,
        state: row.get(3)?,
        title: row.get(4)?,
        record: row.get(5)?,
        applied: row.get(6)?,
        note: row.get(7)?,
        tries: row.get(8)?,
        next_try: row.get(9)?,
        updated: row.get(10)?,
        seconds: row.get(11)?,
        searches: row.get(12)?,
        reads: row.get(13)?,
        original: row.get(14)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_an_item_by_its_file_name_or_key() {
        let store = Store::in_memory().unwrap();
        let item = SportsItem {
            rating_key: "21417".into(),
            section: "4".into(),
            file: "/s/UFC_334 Prelims%.mp4".into(),
            state: "matched".into(),
            title: String::new(),
            record: None,
            applied: None,
            note: String::new(),
            tries: 0,
            next_try: 0,
            updated: 1,
            seconds: 0,
            searches: 0,
            reads: 0,
            original: None,
        };
        store.save_sports_item(&item).unwrap();
        assert!(store.sports_item_named("21417").unwrap().is_some());
        assert!(store.sports_item_named("UFC_334 Prelims%.mp4").unwrap().is_some());
        assert!(store.sports_item_named("UFCx334 Prelims%.mp4").unwrap().is_none());
        assert_eq!(store.sports_per_section().unwrap(), vec![("4".to_string(), 1)]);
        store.forget_sports_section("4").unwrap();
        assert!(store.sports_item("21417").unwrap().is_none());
    }

    #[test]
    fn files_researched_before_effort_was_counted_read_as_unmeasured() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(SCHEMA).unwrap();
        connection.execute("INSERT INTO sports_items (rating_key, section, file, state, updated) VALUES ('1', '4', '/s/a.mkv', 'matched', 1)", []).unwrap();
        let store = Store::with(connection).unwrap();
        let item = store.sports_item("1").unwrap().unwrap();
        assert_eq!((item.seconds, item.searches, item.reads), (UNMEASURED, UNMEASURED, UNMEASURED));
    }

    #[test]
    fn keeps_sports_items_events_and_abilities() {
        let store = Store::in_memory().unwrap();
        let item = SportsItem {
            rating_key: "21417".into(),
            section: "4".into(),
            file: "/s/UFC 334 Prelims.mp4".into(),
            state: "matched".into(),
            title: "UFC 334: Gane vs. Hokit · Prelims".into(),
            record: Some("{}".into()),
            applied: None,
            note: String::new(),
            tries: 1,
            next_try: 0,
            updated: now(),
            seconds: 23,
            searches: 1,
            reads: 2,
            original: None,
        };
        store.save_sports_item(&item).unwrap();
        assert_eq!(store.sports_item("21417").unwrap(), Some(item.clone()));
        assert_eq!(store.sports_counts().unwrap(), vec![("matched".to_string(), 1)]);
        assert_eq!(store.keep_sports_items(&["4".into()], &["1".into()]).unwrap(), 1);
        assert!(store.sports_items(10).unwrap().is_empty());
        store.save_sports_event("UFC 334", "{\"a\":1}").unwrap();
        assert_eq!(store.sports_event("UFC 334").unwrap().map(|(record, _)| record), Some("{\"a\":1}".into()));
        store.save_abilities("bolt@http://x", true, false).unwrap();
        assert_eq!(store.abilities("bolt@http://x").unwrap().map(|(tools, thinking, _)| (tools, thinking)), Some((true, false)));
    }

    #[test]
    fn a_device_is_found_by_its_token_and_never_stores_it() {
        let store = Store::in_memory().unwrap();
        let id = store.add_device("Marcus's iPhone", "ios", "secret-token").unwrap();
        let device = store.device_for_token("secret-token").unwrap().unwrap();
        assert_eq!(device.id, id);
        assert!(store.device_for_token("other").unwrap().is_none());
        let stored: String = store.lock().query_row("SELECT token_hash FROM devices", [], |row| row.get(0)).unwrap();
        assert_ne!(stored, "secret-token");
        assert!(store.remove_device(&id).unwrap());
        assert!(store.device_for_token("secret-token").unwrap().is_none());
    }

    #[test]
    fn a_pending_pairing_is_taken_once() {
        let store = Store::in_memory().unwrap();
        store.add_pending_pairing("abc", &[7; 16], now() + 600).unwrap();
        assert_eq!(store.take_pending_pairing("abc").unwrap().map(|(secret, _)| secret), Some([7; 16]));
        assert!(store.take_pending_pairing("abc").unwrap().is_none());
        store.add_pending_pairing("old", &[1; 16], now() - 1).unwrap();
        assert!(store.take_pending_pairing("old").unwrap().is_some_and(|(_, expires)| expires < now()));
        assert!(store.take_pending_pairing("old").unwrap().is_none());
    }

    #[test]
    fn summaries_are_keyed_by_source_model_and_prompt() {
        let store = Store::in_memory().unwrap();
        let summary = Summary { text: "Goku trains.".into(), grounded: true };
        store.save_summary("41", "abc", "gemma", 1, &summary).unwrap();
        assert_eq!(store.summary("41", "abc", "gemma", 1).unwrap(), Some(summary));
        assert_eq!(store.summary("41", "abc", "gemma", 2).unwrap(), None);
    }
}
