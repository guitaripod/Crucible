//! Who is in the owner's Plex Home, for the My Plex Home policy. plex.tv lists the owner's Home members and every share
//! of this Plex server with the token it gave that person, so a request's Plex token names a Home member exactly when
//! it is one of theirs. The list is asked for at most every ten minutes, and once a minute while someone not on it asks.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use tokio::sync::Mutex;

use crate::plextv::{PlexTv, PlexTvError};
use crate::store::hash_token;

/// How long a list is trusted before plex.tv is asked again.
const FRESH_FOR: Duration = Duration::from_secs(600);
/// How soon someone missing from the list, or a failed ask, makes the server ask again.
const RETRY_AFTER: Duration = Duration::from_secs(60);

pub struct Home {
    plextv: PlexTv,
    owner_token: Option<String>,
    machine_identifier: String,
    known: Mutex<Known>,
}

#[derive(Default)]
struct Known {
    members: Option<HashSet<String>>,
    asked: Option<Instant>,
    failure: Option<String>,
}

impl Home {
    pub fn new(plextv: PlexTv, owner_token: Option<String>, machine_identifier: String) -> Self {
        Home { plextv, owner_token, machine_identifier, known: Mutex::default() }
    }

    /// Whether the person whose Plex token has this hash is in the owner's Plex Home. When plex.tv cannot be asked the
    /// last list it gave decides; without one, the failure is the answer.
    pub async fn admits(&self, hashed: &str) -> Result<bool, PlexTvError> {
        let mut known = self.known.lock().await;
        let age = known.asked.map(|at| at.elapsed());
        let listed = known.members.as_ref().is_some_and(|members| members.contains(hashed));
        match (&known.members, age) {
            (Some(_), Some(age)) if age < FRESH_FOR && (listed || age < RETRY_AFTER) => return Ok(listed),
            (None, Some(age)) if age < RETRY_AFTER => {
                return Err(PlexTvError::Unreachable(known.failure.clone().unwrap_or_default()));
            }
            _ => {}
        }
        known.asked = Some(Instant::now());
        match self.members().await {
            Ok(members) => {
                let listed = members.contains(hashed);
                known.members = Some(members);
                known.failure = None;
                Ok(listed)
            }
            Err(error) => {
                tracing::warn!(%error, "could not ask plex.tv who is in the Plex Home");
                known.failure = Some(error.to_string());
                match &known.members {
                    Some(members) => Ok(members.contains(hashed)),
                    None => Err(error),
                }
            }
        }
    }

    /// The hash that names the owner's own Plex token.
    pub fn owner_token_hash(&self) -> Option<String> {
        self.owner_token.as_deref().map(hash_token)
    }

    /// How many people besides the owner are in the Plex Home with access to this server, for `doctor`.
    pub async fn count(&self) -> Result<usize, PlexTvError> {
        self.members().await.map(|members| members.len())
    }

    async fn members(&self) -> Result<HashSet<String>, PlexTvError> {
        let owner = self.owner_token.as_deref().ok_or(PlexTvError::NotSignedIn)?;
        let tokens = self.plextv.home_tokens(owner, &self.machine_identifier).await?;
        Ok(tokens.iter().map(|token| hash_token(token)).collect())
    }
}
