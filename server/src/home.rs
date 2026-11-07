//! Who is in the owner's Plex Home, for the My Plex Home policy. plex.tv lists the owner's Home members and every share
//! of this Plex server with the token it gave that person, so a request's Plex token names a Home member exactly when
//! it is one of theirs. A list is trusted for ten minutes from when plex.tv gave it; someone missing from it makes the
//! server ask again, at most once a minute, and while plex.tv cannot be asked the last list it gave stands in.

use std::collections::HashSet;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::plextv::{PlexTv, PlexTvError};
use crate::store::hash_token;

/// How long a list is trusted from when plex.tv gave it.
const FRESH_FOR: Duration = Duration::from_secs(600);
/// How soon after any ask, answered or not, the server asks again.
const RETRY_AFTER: Duration = Duration::from_secs(60);

pub struct Home {
    plextv: PlexTv,
    owner_token: Option<String>,
    machine_identifier: String,
    known: Mutex<Known>,
    asking: tokio::sync::Mutex<()>,
}

#[derive(Default)]
struct Known {
    members: Option<HashSet<String>>,
    listed_at: Option<Instant>,
    asked_at: Option<Instant>,
    failure: Option<String>,
}

impl Known {
    /// The answer for `hashed` without asking plex.tv, when the list allows one: fresh and naming them, or asked too
    /// recently to ask again.
    fn answer(&self, hashed: &str) -> Option<Result<bool, PlexTvError>> {
        let listed = self.members.as_ref().is_some_and(|members| members.contains(hashed));
        let fresh = self.listed_at.is_some_and(|at| at.elapsed() < FRESH_FOR);
        let asked_lately = self.asked_at.is_some_and(|at| at.elapsed() < RETRY_AFTER);
        match (&self.members, fresh && listed || asked_lately) {
            (_, false) => None,
            (Some(_), true) => Some(Ok(listed)),
            (None, true) => Some(Err(PlexTvError::Unreachable(self.failure.clone().unwrap_or_default()))),
        }
    }
}

impl Home {
    pub fn new(plextv: PlexTv, owner_token: Option<String>, machine_identifier: String) -> Self {
        Home { plextv, owner_token, machine_identifier, known: Mutex::default(), asking: tokio::sync::Mutex::new(()) }
    }

    /// Whether the person whose Plex token has this hash is in the owner's Plex Home. A request the list already
    /// answers never waits for one that asks plex.tv.
    pub async fn admits(&self, hashed: &str) -> Result<bool, PlexTvError> {
        if let Some(answer) = self.known().answer(hashed) {
            return answer;
        }
        let _asking = self.asking.lock().await;
        if let Some(answer) = self.known().answer(hashed) {
            return answer;
        }
        let asked = self.members().await;
        let mut known = self.known();
        known.asked_at = Some(Instant::now());
        match asked {
            Ok(members) => {
                let listed = members.contains(hashed);
                known.members = Some(members);
                known.listed_at = known.asked_at;
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

    fn known(&self) -> std::sync::MutexGuard<'_, Known> {
        self.known.lock().unwrap_or_else(PoisonError::into_inner)
    }

    async fn members(&self) -> Result<HashSet<String>, PlexTvError> {
        let owner = self.owner_token.as_deref().ok_or(PlexTvError::NotSignedIn)?;
        let tokens = self.plextv.home_tokens(owner, &self.machine_identifier).await?;
        Ok(tokens.iter().map(|token| hash_token(token)).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known(members: &[&str], listed_ago: u64, asked_ago: u64) -> Known {
        let now = Instant::now();
        Known {
            members: Some(members.iter().map(|member| member.to_string()).collect()),
            listed_at: now.checked_sub(Duration::from_secs(listed_ago)),
            asked_at: now.checked_sub(Duration::from_secs(asked_ago)),
            failure: None,
        }
    }

    #[test]
    fn a_fresh_list_answers_for_its_members_and_asks_again_for_others() {
        assert!(matches!(known(&["kids"], 100, 100).answer("kids"), Some(Ok(true))));
        assert!(known(&["kids"], 100, 100).answer("robin").is_none());
        assert!(matches!(known(&["kids"], 100, 10).answer("robin"), Some(Ok(false))));
    }

    #[test]
    fn a_failed_ask_does_not_keep_a_stale_list_fresh() {
        assert!(matches!(known(&["robin"], 700, 30).answer("robin"), Some(Ok(true))));
        assert!(known(&["robin"], 700, 90).answer("robin").is_none());
    }

    #[test]
    fn without_any_list_a_recent_failure_is_the_answer() {
        let failed = Known { asked_at: Some(Instant::now()), failure: Some("plex.tv answered 503".into()), ..Known::default() };
        assert!(matches!(failed.answer("kids"), Some(Err(PlexTvError::Unreachable(_)))));
        assert!(Known::default().answer("kids").is_none());
    }
}
