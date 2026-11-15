//! The research: the owner's model thinks, searches the web and reads pages until it can name the event a file holds,
//! then hands in a record. Code holds it to a budget, checks the record, and sends it back once with what is wrong.

use std::collections::BTreeSet;
use std::time::Instant;

use serde_json::{json, Value};

use super::record::Record;
use super::release::Release;
use super::web::{results_for_model, Web};
use crate::brain::{Brain, BrainError};
use crate::converse::{tool, tool_result, ToolCall};

/// Searches one file's research may make.
pub const SEARCHES: usize = 6;
/// Pages one file's research may read.
pub const READS: usize = 6;
/// Model turns before the research must hand in what it has.
pub const TURNS: usize = 18;
/// Tokens a turn may answer with, beside what it thinks.
const ANSWER_TOKENS: u32 = 4096;

const SYSTEM: &str = "You identify sports recordings in a Plex library and research them on the web, so the library can show proper titles, dates, cards and artwork.

You get one file name. Work like a careful researcher:
1. Read the name. Release names carry the competition, an event number or round, often the main bout or the teams, the part of the broadcast (main card, prelims, early prelims, race, qualifying) and technical words you ignore.
2. Search to identify the exact event. Prefer the league's own site and reference sources (Wikipedia, ESPN, Tapology, Sherdog, CBS Sports, Formula1.com). Confirm the date and venue on a page you read.
3. Read the event's page for its whole card: every bout or fixture of the event in running order, not only the part this file holds, each with its weight class or detail and the section of the card it is on (Main card, Prelims, Early prelims).
4. Look for artwork: read the league's official event page and take the event poster or key art from the images it lists. Give an image address only if a page you read lists it.
5. Call submit once with the record.

Rules:
- Never reveal how the event went: no winners, methods, rounds, scores or title changes anywhere. Describe the matchups and the stakes as they stood before the event.
- State only what you saw in search results or pages. If you cannot identify the event, submit with identified false and say why in notes.
- headline is the main bout or fixture by surnames or team names as the league bills it, such as \"Gane vs. Hokit\" or \"Chiefs vs. Bills\"; leave it empty for races and other events without one.
- event_number is only for leagues that number their events, such as \"UFC 334\", \"UFC Fight Night 286\" or \"PFL 7\"; null for a round or week of a season.
- event for a race or a season's round is its proper name with the year, such as \"2026 Miami Grand Prix\".
- summary is two to four plain sentences in English about the event and its main matchups, as a preview would describe them; never about the file. No hype, no em dashes.
- date is the local date where the event took place, as YYYY-MM-DD.
- league is the short name the league goes by, such as UFC, PFL, NFL or Formula 1. venue is the arena or circuit's name alone; city is the city and country, such as \"New York City, United States\".
- Keep tool calls purposeful: at most six searches and six page reads. Never repeat a search.";

/// One step of the research, for the owner to watch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Thinking,
    Searching(String),
    Reading(String),
    Checking,
}

/// A finished research: the checked record and what it took.
#[derive(Clone, Debug)]
pub struct Research {
    pub record: Record,
    pub turns: usize,
    pub searches: usize,
    pub reads: usize,
    pub seconds: u64,
}

#[derive(Debug, thiserror::Error)]
pub enum ResearchError {
    #[error(transparent)]
    Model(#[from] BrainError),
    #[error("{0}")]
    NoRecord(String),
    /// The search engine turned the research away for now; the file is tried again later, not marked unidentifiable.
    #[error("{0}")]
    SearchBusy(String),
}

/// The submit tool of a sports record.
fn sports_submit() -> Value {
    tool(
        "submit",
        "Hand in the finished record. Call exactly once, at the end.",
        json!({"type": "object", "properties": {
            "identified": {"type": "boolean"},
            "sport": {"type": "string", "description": "Such as Mixed Martial Arts, Formula 1, American Football"},
            "league": {"type": "string", "description": "The organisation or competition, such as UFC"},
            "event": {"type": "string", "description": "The event's canonical name, such as \"UFC 334: Gane vs. Hokit\""},
            "event_number": {"type": ["string", "null"], "description": "The league's own event numbering, such as \"UFC 334\" or \"UFC Fight Night 286\"; null for a round or week of a season"},
            "part": {"type": ["string", "null"], "description": "The part of the broadcast this file holds"},
            "date": {"type": "string", "description": "YYYY-MM-DD, local date of the event"},
            "venue": {"type": "string", "description": "The arena or circuit's name alone"},
            "city": {"type": "string", "description": "City and country, such as \"New York City, United States\""},
            "headline": {"type": "string"},
            "lineup": {"type": "array", "description": "Every bout or fixture in running order, with no results", "items": {"type": "object", "properties": {
                "matchup": {"type": "string", "description": "Such as \"Ciryl Gane vs. Josh Hokit\""},
                "detail": {"type": "string", "description": "Such as \"Heavyweight\" or \"Lightweight title\""},
                "part": {"type": ["string", "null"], "description": "Main card, Prelims or Early prelims"}}, "required": ["matchup"]}},
            "summary": {"type": "string"},
            "poster_url": {"type": ["string", "null"]},
            "background_url": {"type": ["string", "null"]},
            "sources": {"type": "array", "items": {"type": "string"}, "description": "Addresses of the pages that confirm the facts"},
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
            "notes": {"type": "string"}},
            "required": ["identified", "event", "date", "summary", "sources", "confidence"]}),
    )
}

/// The tools a research may call: searching, reading and handing in, or only handing in once it must finish.
pub fn tools(submit: &Value, only_submit: bool) -> Vec<Value> {
    let submit = submit.clone();
    if only_submit {
        return vec![submit];
    }
    vec![
        tool(
            "web_search",
            "Search the web. Returns up to eight results with title, url and snippet.",
            json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
        ),
        tool(
            "read_page",
            "Read a public web page: its title, its text cut to 9000 characters, and the images it offers as artwork.",
            json!({"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
        ),
        submit,
    ]
}

/// Characters of each page the model reads, so six pages, six searches and the instructions fit its window with room to
/// think and answer: the full 9000 from a 48K window up, less below.
pub fn page_room(context: u32) -> usize {
    let characters = context as usize * 3;
    (characters.saturating_sub(50_000) / (READS + 1)).clamp(2_500, super::web::PAGE_TEXT)
}

/// What the model is told about the file before it starts.
pub fn brief(release: &Release, added: &str) -> String {
    let mut lines = vec![format!("File name: {}", release.file_name), format!("Name without technical words: {}", release.cleaned)];
    if let Some(event) = &release.event {
        lines.push(format!("The name numbers the event {event}."));
    }
    if let Some(part) = &release.part {
        lines.push(format!("By the league's naming, the file holds: {part}."));
    }
    if let Some(caution) = release.caution {
        lines.push(caution.to_string());
    }
    if !added.is_empty() {
        lines.push(format!("Added to the library on {added}, so the event took place on or before that day."));
    }
    lines.join("\n")
}

pub fn folded(query: &str) -> String {
    query.to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ")
}

/// What a research saw: the addresses its searches returned and its pages had, and the images each page offered.
#[derive(Default)]
pub struct Seen {
    pub known: BTreeSet<String>,
    pub images: BTreeSet<String>,
    pub page_images: Vec<(String, Vec<String>)>,
    /// The text of every page read, for checks that look at what the pages said.
    pub texts: Vec<String>,
}

/// What a research took.
pub struct Took {
    pub turns: usize,
    pub searches: usize,
    pub reads: usize,
    pub seconds: u64,
}

/// The research loop every kind of file shares: the model thinks, searches and reads within the budget until it calls
/// submit; `check` turns that call into a checked record, or the problems the model is sent back once to fix.
pub async fn investigate<T>(
    brain: &Brain,
    web: &Web,
    system: &str,
    brief: String,
    submit: &Value,
    step: &(dyn Fn(Step) + Send + Sync),
    mut check: impl FnMut(&ToolCall, &Seen, bool) -> Result<T, Vec<String>>,
) -> Result<(T, Took), ResearchError> {
    let started = Instant::now();
    let mut messages = vec![json!({"role": "system", "content": system}), json!({"role": "user", "content": brief})];
    let mut seen = Seen::default();
    let mut asked: BTreeSet<String> = BTreeSet::new();
    let (mut searches, mut reads, mut sent_back) = (0, 0, false);
    for turn in 0..TURNS {
        let force = turn + 2 >= TURNS || (searches >= SEARCHES && reads >= READS);
        step(Step::Thinking);
        let said = brain.converse(&messages, &tools(submit, force), force, ANSWER_TOKENS).await?;
        messages.push(said.as_message());
        if said.calls.is_empty() {
            messages.push(json!({"role": "user", "content": "Use the tools, and finish by calling submit with the record."}));
            continue;
        }
        for call in &said.calls {
            let answer = match call.name.as_str() {
                "web_search" => {
                    let query = call.arguments["query"].as_str().unwrap_or("").trim().to_string();
                    if searches >= SEARCHES {
                        json!({"error": "The search budget is spent: read a page you found, or submit."})
                    } else if query.is_empty() || !asked.insert(folded(&query)) {
                        json!({"error": "That search was already made or is empty: search with other words, read a result, or submit."})
                    } else {
                        searches += 1;
                        step(Step::Searching(query.clone()));
                        match web.search(&query).await {
                            Ok(found) => {
                                seen.known.extend(found.iter().map(|result| result.url.clone()));
                                results_for_model(&found)
                            }
                            Err(
                                error @ (super::web::WebError::Busy(_)
                                | super::web::WebError::Unreachable(..)
                                | super::web::WebError::Status(..)
                                | super::web::WebError::NoKey),
                            ) => return Err(ResearchError::SearchBusy(error.to_string())),
                            Err(error) => json!({"error": error.to_string()}),
                        }
                    }
                }
                "read_page" => {
                    let url = call.arguments["url"].as_str().unwrap_or("").trim().to_string();
                    if reads >= READS {
                        json!({"error": "The reading budget is spent: submit with what you have."})
                    } else {
                        reads += 1;
                        step(Step::Reading(url.clone()));
                        match web.read(&url, page_room(brain.model.context)).await {
                            Ok(page) => {
                                seen.known.insert(url.clone());
                                seen.known.insert(page.url.clone());
                                seen.images.extend(page.images.iter().cloned());
                                seen.page_images.push((page.url.clone(), page.images.clone()));
                                seen.texts.push(format!("{} {}", page.title, page.text));
                                json!(page)
                            }
                            Err(error) => json!({"error": error.to_string()}),
                        }
                    }
                }
                "submit" => {
                    step(Step::Checking);
                    match check(call, &seen, sent_back) {
                        Ok(record) => {
                            return Ok((record, Took { turns: turn + 1, searches, reads, seconds: started.elapsed().as_secs() }));
                        }
                        Err(problems) if !sent_back => {
                            sent_back = true;
                            json!({"accepted": false, "problems": problems, "do": "Fix these and call submit again."})
                        }
                        Err(problems) => return Err(ResearchError::NoRecord(problems.join(" "))),
                    }
                }
                other => json!({"error": format!("There is no tool called {other}.")}),
            };
            messages.push(tool_result(call, &answer));
        }
    }
    Err(ResearchError::NoRecord(format!("the model handed in no record within {TURNS} turns")))
}

/// Researches the file `release` names. `newest` is the last day (days since 1970) the event can have been, from
/// when Plex added the file, and `added` the same day written out for the model.
pub async fn research(
    brain: &Brain,
    web: &Web,
    release: &Release,
    added: &str,
    newest: i64,
    step: &(dyn Fn(Step) + Send + Sync),
) -> Result<Research, ResearchError> {
    let (record, took) = investigate(brain, web, SYSTEM, brief(release, added), &sports_submit(), step, |call, seen, sent_back| {
        let mut record = settle(call, release, &seen.known, &seen.images, newest, sent_back)?;
        if record.poster_url.is_none() {
            record.poster_url = official_artwork(&record, &seen.page_images);
        }
        Ok(record)
    })
    .await?;
    Ok(Research { record, turns: took.turns, searches: took.searches, reads: took.reads, seconds: took.seconds })
}

/// Artwork for a record that names none: the leading image of the first page it cites that is not an encyclopedia's,
/// which on a league's own event page is the event's key art.
fn official_artwork(record: &Record, pages: &[(String, Vec<String>)]) -> Option<String> {
    let reference = |url: &str| ["wikipedia.org", "wikimedia.org", "wikidata.org"].iter().any(|host| url.contains(host));
    pages
        .iter()
        .filter(|(url, _)| !reference(url) && record.sources.iter().any(|source| source.trim_end_matches('/') == url.trim_end_matches('/')))
        .find_map(|(_, images)| images.iter().find(|image| !reference(image)).cloned())
}

/// The record a submit call carries, settled and checked. Artwork no page offered is dropped quietly; a record that
/// is still wrong after being sent back keeps only what is safe, or fails.
fn settle(
    call: &ToolCall,
    release: &Release,
    known: &BTreeSet<String>,
    images: &BTreeSet<String>,
    newest: i64,
    sent_back: bool,
) -> Result<Record, Vec<String>> {
    let mut record: Record = serde_json::from_value(call.arguments.clone()).map_err(|error| vec![format!("The record does not match the schema: {error}.")])?;
    record.settle(release);
    for artwork in [&mut record.poster_url, &mut record.background_url] {
        if artwork.as_ref().is_some_and(|url| !images.contains(url)) {
            *artwork = None;
        }
    }
    let problems = record.problems(release, known, newest);
    if problems.is_empty() {
        return Ok(record);
    }
    let only_spoilers = problems.iter().all(|problem| problem.contains("gives results away"));
    if sent_back && only_spoilers {
        record.summary = super::record::without_spoilers(&record.summary);
        record.event = super::record::without_spoilers(&record.event);
        record.lineup.retain(|bout| super::record::spoilers(&format!("{} {}", bout.matchup, bout.detail)).is_empty());
        if !super::record::spoilers(&record.headline).is_empty() {
            record.headline.clear();
        }
        record.confidence = "low".into();
        return Ok(record);
    }
    Err(problems)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::brain::testing::{start, Received};
    use crate::config::Model;
    use crate::sports::record::days_from_civil;
    use crate::sports::web::Engine;

    fn call(name: &str, arguments: Value) -> Value {
        json!({"choices": [{"message": {"content": "", "reasoning_content": "thinking", "tool_calls": [{"id": format!("c-{name}"), "type": "function", "function": {"name": name, "arguments": arguments.to_string()}}]}}]})
    }

    async fn searxng() -> String {
        use axum::routing::get;
        let router = axum::Router::new().route(
            "/search",
            get(|| async { axum::Json(json!({"results": [{"title": "UFC 334", "url": "https://en.wikipedia.org/wiki/UFC_334", "content": "14 November 2026 at Madison Square Garden"}]})) }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        url
    }

    fn record(summary: &str) -> Value {
        json!({"identified": true, "sport": "Mixed Martial Arts", "league": "UFC", "event": "UFC 334: Gane vs. Hokit", "event_number": "UFC 334",
            "part": "Prelims", "date": "2026-11-14", "venue": "Madison Square Garden", "headline": "Gane vs. Hokit", "summary": summary,
            "lineup": [{"matchup": "Stephen Thompson vs. Charles Radtke", "detail": "Welterweight", "part": "Prelims"}],
            "poster_url": "https://invented.example/poster.jpg", "sources": ["https://en.wikipedia.org/wiki/UFC_334"], "confidence": "high"})
    }

    #[tokio::test]
    async fn searches_submits_is_sent_back_once_and_drops_invented_artwork() {
        let web = Web::new(Engine::Searxng { url: searxng().await }, None);
        let service = start(
            &["bolt"],
            Arc::new(|received: &[Received]| {
                let reply = match received.len() {
                    1 => call("web_search", json!({"query": "UFC 334 prelims"})),
                    2 => call("submit", record("Gane defeated Hokit.")),
                    _ => call("submit", record("Two heavyweights meet at the Garden.")),
                };
                (200, Vec::new(), reply)
            }),
        )
        .await;
        let brain = Brain::new(Model { url: service.url.clone(), name: "bolt".into(), context: 65_536 });
        let steps = Arc::new(Mutex::new(Vec::new()));
        let seen = steps.clone();
        let release = Release::read("UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4");
        let done = research(&brain, &web, &release, "2026-11-15", days_from_civil(2026, 11, 15), &move |step| seen.lock().unwrap().push(step)).await.unwrap();
        assert_eq!(done.record.summary, "Two heavyweights meet at the Garden.");
        assert_eq!(done.record.poster_url, None);
        assert_eq!((done.searches, done.reads, done.turns), (1, 0, 3));
        assert!(steps.lock().unwrap().contains(&Step::Searching("UFC 334 prelims".into())));
        let sent = service.received.lock().unwrap().clone();
        let third = sent[2].body["messages"].to_string();
        assert!(third.contains("gives results away") && !third.contains("\"thinking\""));
    }

    #[tokio::test]
    async fn a_model_that_never_hands_in_is_made_to_and_a_repeat_search_is_refused() {
        let web = Web::new(Engine::Searxng { url: searxng().await }, None);
        let service = start(
            &["bolt"],
            Arc::new(|received: &[Received]| {
                let body = &received.last().unwrap().body;
                let forced = body["tool_choice"] == "required";
                let reply = if forced {
                    call("submit", json!({"identified": false, "event": "", "date": "", "summary": "", "sources": [], "confidence": "low", "notes": "unknown"}))
                } else {
                    call("web_search", json!({"query": "same thing"}))
                };
                (200, Vec::new(), reply)
            }),
        )
        .await;
        let brain = Brain::new(Model { url: service.url.clone(), name: "bolt".into(), context: 65_536 });
        let release = Release::read("Mystery.Event.1080p.WEB.h264-X.mkv");
        let done = research(&brain, &web, &release, "", i64::MAX, &|_| {}).await.unwrap();
        assert!(!done.record.identified);
        assert_eq!(done.searches, 1);
        let sent = service.received.lock().unwrap().clone();
        assert!(sent.iter().any(|request| request.body["messages"].to_string().contains("already made")));
        assert_eq!(sent.last().unwrap().body["tools"].as_array().unwrap().len(), 1);
    }
}
