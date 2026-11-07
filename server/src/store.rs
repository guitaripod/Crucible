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
        let found: Option<(String, i64)> = connection
            .query_row("SELECT secret, expires FROM pending_pairings WHERE id = ?1", params![id], |row| Ok((row.get(0)?, row.get(1)?)))
            .optional()?;
        connection.execute("DELETE FROM pending_pairings WHERE id = ?1", params![id])?;
        Ok(found.and_then(|(secret, expires)| hex::decode(secret).ok()?.try_into().ok().map(|secret| (secret, expires))))
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

#[cfg(test)]
mod tests {
    use super::*;

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
