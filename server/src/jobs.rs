//! Work a device asked for and waits on: a recap or an answer runs in the background, and the device long-polls for
//! it. A job belongs to the person who asked; anyone else is told it does not exist.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::watch;

/// How long a finished job's result is kept for the device to collect.
const KEPT_FOR: Duration = Duration::from_secs(30 * 60);
/// Jobs one person may have running at once.
pub const PER_PERSON: usize = 2;

/// Where a job is.
#[derive(Clone, Debug, PartialEq)]
pub enum State {
    Working,
    Done(Value),
    Failed(String),
}

struct Job {
    person: String,
    created: Instant,
    state: watch::Receiver<State>,
}

#[derive(Default)]
pub struct Jobs {
    jobs: Mutex<HashMap<String, Job>>,
}

impl Jobs {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Job>> {
        self.jobs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether `person` may start another job now.
    pub fn has_room(&self, person: &str) -> bool {
        let jobs = self.lock();
        jobs.values().filter(|job| job.person == person && *job.state.borrow() == State::Working).count() < PER_PERSON
    }

    /// Runs `work` in the background and returns the job's id.
    pub fn start<F>(&self, person: &str, work: F) -> String
    where
        F: Future<Output = Result<Value, String>> + Send + 'static,
    {
        let id = uuid::Uuid::new_v4().to_string();
        let (sender, receiver) = watch::channel(State::Working);
        {
            let mut jobs = self.lock();
            jobs.retain(|_, job| job.created.elapsed() < KEPT_FOR);
            jobs.insert(id.clone(), Job { person: person.into(), created: Instant::now(), state: receiver });
        }
        tokio::spawn(async move {
            let state = match work.await {
                Ok(value) => State::Done(value),
                Err(message) => State::Failed(message),
            };
            let _ = sender.send(state);
        });
        id
    }

    /// The job's state, waiting up to `wait` for it to finish; `None` when there is no such job for this person.
    pub async fn wait(&self, id: &str, person: &str, wait: Duration) -> Option<State> {
        let mut receiver = {
            let jobs = self.lock();
            let job = jobs.get(id).filter(|job| job.person == person)?;
            job.state.clone()
        };
        let _ = tokio::time::timeout(wait, receiver.wait_for(|state| *state != State::Working)).await;
        let state = receiver.borrow().clone();
        Some(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn a_job_belongs_to_whoever_started_it() {
        let jobs = Jobs::default();
        let id = jobs.start("marcus", async { Ok(json!({"text": "hi"})) });
        assert_eq!(jobs.wait(&id, "marcus", Duration::from_secs(5)).await, Some(State::Done(json!({"text": "hi"}))));
        assert_eq!(jobs.wait(&id, "dana", Duration::from_secs(1)).await, None);
    }

    #[tokio::test]
    async fn waiting_returns_working_when_time_runs_out() {
        let jobs = Jobs::default();
        let id = jobs.start("marcus", async {
            tokio::time::sleep(Duration::from_secs(5)).await;
            Ok(Value::Null)
        });
        assert_eq!(jobs.wait(&id, "marcus", Duration::from_millis(50)).await, Some(State::Working));
        assert!(jobs.has_room("marcus"));
        let _second = jobs.start("marcus", async {
            tokio::time::sleep(Duration::from_secs(5)).await;
            Ok(Value::Null)
        });
        assert!(!jobs.has_room("marcus"));
    }
}
