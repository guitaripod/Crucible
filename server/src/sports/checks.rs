//! What sports research needs before it runs, each checked for real: the owner signed in, a model that is there, calls
//! tools on its own, thinks, and has room to read pages, a search engine that answers, the owner's agreement to where
//! searches go, a library to read, and the switch on. Each check says what to do when it is not met.

use serde::Serialize;

use crate::brain::Brain;
use crate::config::{Model, Sports as Settings};
use crate::plex::Plex;
use crate::store::{now, Store};

use super::web::Web;

/// The smallest context window the research works in: a few pages of text beside the instructions.
pub const SMALLEST_CONTEXT: u32 = 32_768;
/// How long a model's probed abilities are trusted before it is asked again.
const ABILITIES_KEPT: i64 = 24 * 3600;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Done,
    Missing,
    Failed,
}

/// One requirement and where it stands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    pub id: &'static str,
    /// The setup step it belongs to: `plex`, `model`, `web` or `library`.
    pub group: &'static str,
    pub state: State,
    pub detail: String,
    /// What the owner does about it, on the server or in the app; none once it is done.
    pub fix: Option<String>,
}

/// The setup step a requirement belongs to.
pub fn group(id: &str) -> &'static str {
    match id {
        "owner" => "plex",
        "model" | "tools" | "thinking" | "context" => "model",
        "search" | "agreement" => "web",
        _ => "library",
    }
}

fn done(id: &'static str, detail: impl Into<String>) -> Check {
    Check { id, group: group(id), state: State::Done, detail: detail.into(), fix: None }
}

fn not_yet(id: &'static str, state: State, detail: impl Into<String>, fix: impl Into<String>) -> Check {
    Check { id, group: group(id), state, detail: detail.into(), fix: Some(fix.into()) }
}

/// The key a model's probed abilities are kept under.
pub fn model_key(model: &Model) -> String {
    format!("{}@{}", model.name, model.url.trim_end_matches('/'))
}

/// Everything the research needs, in the order the owner meets it.
pub struct Inputs<'a> {
    pub plex: &'a Plex,
    pub owner_token: Option<&'a str>,
    pub owner: &'a str,
    pub model: Option<&'a Model>,
    pub brain: Option<&'a Brain>,
    pub web: Option<&'a Web>,
    pub settings: &'a Settings,
    pub library_titles: &'a [(String, String, bool)],
    pub store: &'a Store,
    /// Ask the model again even when its abilities were probed lately.
    pub probe_again: bool,
}

pub async fn run(inputs: Inputs<'_>) -> Vec<Check> {
    let mut checks = Vec::new();
    checks.push(match inputs.owner_token {
        None => not_yet("owner", State::Missing, "The server has no Plex sign-in of the owner's.", "On the server: crucible-server setup"),
        Some(token) => match inputs.plex.accepts(token).await {
            Ok(true) => done("owner", format!("Signed in as {}, who may edit the library.", inputs.owner)),
            Ok(false) => not_yet("owner", State::Failed, "Plex no longer accepts the owner's sign-in.", "On the server: crucible-server setup"),
            Err(error) => not_yet("owner", State::Failed, error.to_string(), "Start Plex Media Server on the server."),
        },
    });
    let (model, brain) = match (inputs.model, inputs.brain) {
        (Some(model), Some(brain)) => (model, brain),
        _ => {
            let fix = "On the server: crucible-server model --url http://127.0.0.1:8080/v1 --name <model>";
            checks.push(not_yet("model", State::Missing, "No model is set.", fix));
            for id in ["tools", "thinking", "context"] {
                checks.push(not_yet(id, State::Missing, "Needs a model first.", fix));
            }
            return finish(checks, inputs).await;
        }
    };
    let host = reqwest::Url::parse(&model.url).ok().and_then(|url| url.host_str().map(str::to_string)).unwrap_or_else(|| model.url.clone());
    match brain.has_model().await {
        Ok(true) => checks.push(done("model", format!("{} on {host}.", model.name))),
        Ok(false) => checks.push(not_yet(
            "model",
            State::Failed,
            format!("{host} no longer offers {}.", model.name),
            "On the server: crucible-server model --name <model>",
        )),
        Err(error) => checks.push(not_yet("model", State::Failed, error.to_string(), format!("Start the model server at {}.", model.url))),
    }
    let key = model_key(model);
    let kept = inputs.store.abilities(&key).ok().flatten().filter(|(_, _, checked)| !inputs.probe_again && now() - checked < ABILITIES_KEPT);
    let abilities = match kept {
        Some((tools, thinking, _)) => Ok((tools, thinking)),
        None if checks.last().is_some_and(|check| check.state == State::Done) => match brain.abilities().await {
            Ok(found) => {
                let _ = inputs.store.save_abilities(&key, found.tools, found.thinking);
                Ok((found.tools, found.thinking))
            }
            Err(error) => Err(error.to_string()),
        },
        None => Err("the model did not answer".to_string()),
    };
    match abilities {
        Ok((tools, thinking)) => {
            checks.push(if tools {
                done("tools", format!("{} calls tools on its own.", model.name))
            } else {
                not_yet(
                    "tools",
                    State::Failed,
                    format!("{} answered in words when it should have called a tool.", model.name),
                    "Serve a model that calls tools (Qwen 3.5, Nemotron 3.5, gpt-oss, Gemma 4) with tool calling on, such as llama.cpp's --jinja.",
                )
            });
            checks.push(if thinking {
                done("thinking", format!("{} thinks before it answers.", model.name))
            } else {
                not_yet(
                    "thinking",
                    State::Failed,
                    format!("{} answers without thinking first.", model.name),
                    "Serve a reasoning model, or turn its thinking on.",
                )
            });
        }
        Err(error) => {
            checks.push(not_yet("tools", State::Failed, format!("Could not ask the model: {error}."), "Check the model, then check again."));
            checks.push(not_yet("thinking", State::Failed, "Needs the model to answer first.", "Check the model, then check again."));
        }
    }
    checks.push(if model.context >= SMALLEST_CONTEXT {
        done("context", format!("{}K tokens, room for several pages.", model.context / 1024))
    } else {
        not_yet(
            "context",
            State::Failed,
            format!("{}K tokens is too little to read pages; it needs 32K.", model.context / 1024),
            "On the server: crucible-server model --context 65536 (and serve the model with that window)",
        )
    });
    finish(checks, inputs).await
}

async fn finish(mut checks: Vec<Check>, inputs: Inputs<'_>) -> Vec<Check> {
    let settings = inputs.settings;
    checks.push(match (inputs.web, &settings.engine) {
        (Some(_), Some(engine)) if !settings.agreed_to_engine() => not_yet(
            "search",
            State::Missing,
            format!("{} is set, and is tried once you agree to where searches go.", engine.label()),
            "Agree in Crucible, or on the server: crucible-server sports --agree",
        ),
        (Some(web), Some(engine)) => match web.works().await {
            Ok(found) if found > 0 => done("search", format!("{} answers.", engine.label())),
            Ok(_) => not_yet("search", State::Failed, format!("{} found nothing for a test search.", engine.label()), "Check the engines your search uses."),
            Err(error) => {
                not_yet("search", State::Failed, error.to_string(), "Start the search engine, or choose another: crucible-server sports --searxng <url>")
            }
        },
        _ => not_yet(
            "search",
            State::Missing,
            "No search engine is set.",
            "On the server: crucible-server sports --searxng http://127.0.0.1:8888 (a SearXNG with its JSON format on), or --brave-key-file <file>",
        ),
    });
    checks.push(match &settings.engine {
        Some(engine) if settings.agreed_to_engine() => done("agreement", format!("Searches and page reads go to {}.", engine.destination())),
        Some(engine) => not_yet(
            "agreement",
            State::Missing,
            format!("Searches naming your sports files' events go to {}, and public pages are read from this server.", engine.destination()),
            "Agree in Crucible, or on the server: crucible-server sports --agree",
        ),
        None => not_yet("agreement", State::Missing, "Needs a search engine first.", "Set a search engine first."),
    });
    let chosen: Vec<&(String, String, bool)> = inputs.library_titles.iter().filter(|(key, _, _)| settings.libraries.contains(key)).collect();
    checks.push(if chosen.is_empty() {
        not_yet(
            "libraries",
            State::Missing,
            "No library is chosen.",
            "Choose an Other Videos library in Crucible, or on the server: crucible-server sports --library <name>",
        )
    } else if let Some((_, title, _)) = chosen.iter().find(|(_, _, other_videos)| !other_videos) {
        not_yet("libraries", State::Failed, format!("{title} is not an Other Videos library."), "Choose libraries Plex keeps as Other Videos.")
    } else {
        done("libraries", chosen.iter().map(|(_, title, _)| title.as_str()).collect::<Vec<_>>().join(", "))
    });
    checks.push(if settings.on {
        done("on", "Research runs as new files arrive.")
    } else {
        not_yet("on", State::Missing, "Research is off.", "Turn it on in Crucible, or on the server: crucible-server sports --on")
    });
    checks
}

/// Whether every requirement is met.
pub fn ready(checks: &[Check]) -> bool {
    !checks.is_empty() && checks.iter().all(|check| check.state == State::Done)
}
