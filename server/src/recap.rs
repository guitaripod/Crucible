//! What the brain writes: a grounded summary of each finished episode (kept, keyed by its dialogue, model and
//! prompt), a Previously On built from those, and answers to a question asked mid-episode. Nothing past what the
//! person has watched ever reaches the model.

use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::brain::{cited_sentences, ungrounded_names, Brain, BrainError, Cited};
use crate::config::Config;
use crate::dialogue::{self, Line};
use crate::plex::{Item, Plex, PlexError};
use crate::segments;
use crate::store::{Store, Summary};

/// Bumped whenever a prompt changes, so kept summaries are rewritten.
pub const PROMPT_VERSION: i64 = 1;
/// Finished episodes a Previously On draws on.
const RECAP_EPISODES: usize = 3;
/// Finished episodes an answer may lean on besides the current one.
const ANSWER_EPISODES: usize = 5;
/// Dialogue lines read per episode, enough for a long episode.
const MAX_LINES: usize = 1200;

#[derive(Debug, thiserror::Error)]
pub enum WriteError {
    #[error(transparent)]
    Plex(#[from] PlexError),
    #[error(transparent)]
    Brain(#[from] BrainError),
    #[error("nothing has been watched yet")]
    NothingWatched,
}

/// A Previously On as a device shows it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recap {
    pub text: String,
    pub based_on: Vec<String>,
    pub grounded: bool,
    pub generated: bool,
    pub model: String,
}

/// An answer to a question asked while watching.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub text: String,
    pub grounded: bool,
    pub model: String,
}

/// One episode's summary and where it came from.
#[derive(Clone, Debug)]
pub struct EpisodeSummary {
    pub label: String,
    pub title: String,
    pub text: String,
    pub grounded: bool,
}

pub struct Writer {
    pub plex: Plex,
    pub brain: Brain,
    pub store: Arc<Store>,
    pub config: Arc<Config>,
}

const SUMMARY_SYSTEM: &str = "You summarise one TV episode for a \"previously on\" recap. Use only the synopsis, characters and dialogue you are given. \
Never add a name, event, relationship or fact that is not in them, and never guess what happens next. Write 3 to 5 short sentences in English, present tense. \
For each sentence give the timestamp of the dialogue line it rests on. Reply with JSON only: {\"sentences\":[{\"text\":\"...\",\"at\":\"12:34\"}]}";

const CHECK_SYSTEM: &str = "You check a summary against its sources. For each numbered sentence decide whether the sources state it or directly imply it. \
Reply with JSON only: {\"unsupported\":[the numbers of sentences the sources do not support]}";

const RECAP_SYSTEM: &str = "You write the \"previously on\" a viewer reads before the next episode. Use only the episode summaries you are given; \
never add a name or fact that is not in them. Weight the most recent episode most. Write 50 to 90 words in English, present tense, no heading. \
Reply with JSON only: {\"text\":\"...\"}";

const ANSWER_SYSTEM: &str = "You answer a viewer's question about the show they are watching. Use only the dialogue of the current episode up to where they paused \
and the summaries of episodes they finished. Never reveal anything beyond that, never add a name or fact that is not in the context, and if the context does not \
answer the question, say so plainly. Answer in at most three sentences in English. Reply with JSON only: {\"text\":\"...\"}";

const TRANSLATE_SYSTEM: &str =
    "Translate the text into the requested language for a TV app. Keep every name exactly as written. Reply with JSON only: {\"text\":\"...\"}";

fn sha(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// The subtitle stream to read: the requested language, else English, else any text track.
fn pick_stream(item: &Item, language: &str) -> Option<crate::plex::Stream> {
    let streams: Vec<&crate::plex::Stream> =
        item.part()?.streams.iter().filter(|stream| stream.is_subtitle() && stream.is_text() && stream.forced != Some(true)).collect();
    let wanted = iso639_2(language);
    streams
        .iter()
        .find(|stream| stream.language_code.as_deref() == Some(wanted))
        .or_else(|| streams.iter().find(|stream| stream.language_code.as_deref() == Some("eng")))
        .or_else(|| streams.first())
        .map(|stream| (*stream).clone())
}

fn iso639_2(language: &str) -> &'static str {
    match language.split(['-', '_']).next().unwrap_or("en") {
        "de" => "ger",
        "es" => "spa",
        "fr" => "fre",
        "it" => "ita",
        "ja" => "jpn",
        "ko" => "kor",
        "pl" => "pol",
        "pt" => "por",
        "zh" => "chi",
        _ => "eng",
    }
}

fn language_name(language: &str) -> Option<&'static str> {
    match language {
        "de" | "de-DE" => Some("German"),
        "es" | "es-ES" => Some("Spanish"),
        "fr" | "fr-FR" => Some("French"),
        "it" => Some("Italian"),
        "ja" => Some("Japanese"),
        "ko" => Some("Korean"),
        "pl" => Some("Polish"),
        "pt-BR" | "pt" => Some("Brazilian Portuguese"),
        "zh-Hans" | "zh-CN" => Some("Simplified Chinese"),
        "zh-Hant" | "zh-TW" => Some("Traditional Chinese"),
        _ => None,
    }
}

/// Everything a summary of one episode may rest on.
pub struct SummarySource {
    pub show: String,
    pub label: String,
    pub title: String,
    pub synopsis: String,
    pub roster: String,
    pub lines: Vec<Line>,
}

/// Writes a summary from `source` and checks it: every name must appear in the source and every sentence must be
/// supported. A refused summary is written once more with the failures named; a second refusal falls back to the
/// synopsis, marked as not grounded.
pub async fn write_summary(brain: &Brain, source: &SummarySource) -> Result<(String, bool), WriteError> {
    let transcript = dialogue::transcript(&dialogue::fit(source.lines.clone(), brain.dialogue_budget(700)));
    let SummarySource { show, label, title, synopsis, roster, .. } = source;
    let context = format!("{show}\n{title}\n{synopsis}\n{roster}\n{transcript}");
    let prompt = format!("Show: {show}\nEpisode: {label} \"{title}\"\nSynopsis: {synopsis}\nCharacters: {roster}\nDialogue:\n{transcript}");
    let mut feedback = String::new();
    for attempt in 0..2 {
        let reply = brain.ask_json(SUMMARY_SYSTEM, &format!("{prompt}{feedback}"), 700).await?;
        let sentences = cited_sentences(&reply);
        if sentences.is_empty() {
            feedback = "\n\nYour last reply was not the JSON asked for.".into();
            continue;
        }
        let text = sentences.iter().map(|sentence| sentence.text.as_str()).collect::<Vec<_>>().join(" ");
        let names = ungrounded_names(&text, &context);
        let unsupported = if names.is_empty() { unsupported(brain, &sentences, synopsis, &transcript).await? } else { Vec::new() };
        if names.is_empty() && unsupported.is_empty() {
            return Ok((text, true));
        }
        let supported: Vec<&str> = sentences.iter().filter(|sentence| !unsupported.contains(sentence)).map(|sentence| sentence.text.as_str()).collect();
        if attempt == 1 && names.is_empty() && supported.len() >= 2 {
            return Ok((supported.join(" "), true));
        }
        tracing::info!(names = ?names, unsupported = unsupported.len(), "summary refused");
        feedback = format!(
            "\n\nYour last summary was refused. {}{}Write it again from the sources only.",
            if names.is_empty() { String::new() } else { format!("These names are not in the sources: {}. ", names.join(", ")) },
            if unsupported.is_empty() {
                String::new()
            } else {
                format!(
                    "These sentences are not supported: {}. ",
                    unsupported.iter().map(|sentence| format!("\"{}\"", sentence.text)).collect::<Vec<_>>().join(" ")
                )
            }
        );
    }
    Ok((synopsis.clone(), false))
}

async fn unsupported(brain: &Brain, sentences: &[Cited], synopsis: &str, transcript: &str) -> Result<Vec<Cited>, WriteError> {
    let numbered = sentences.iter().enumerate().map(|(index, sentence)| format!("{}. {}", index + 1, sentence.text)).collect::<Vec<_>>().join("\n");
    let reply = brain.ask_json(CHECK_SYSTEM, &format!("Sources:\nSynopsis: {synopsis}\nDialogue:\n{transcript}\n\nSentences:\n{numbered}"), 200).await?;
    Ok(reply["unsupported"]
        .as_array()
        .map(|numbers| numbers.iter().filter_map(Value::as_u64).filter_map(|number| sentences.get(number.saturating_sub(1) as usize).cloned()).collect())
        .unwrap_or_default())
}

impl Writer {
    fn model_key(&self) -> String {
        self.brain.model.name.clone()
    }

    /// The story's dialogue of an item, or nothing when it has no readable text subtitles.
    pub async fn dialogue(&self, item: &Item, token: &str) -> Vec<Line> {
        let Some(stream) = pick_stream(item, "en") else { return Vec::new() };
        let srt = if let Some(key) = stream.key.as_deref().filter(|key| key.starts_with("/library/streams/")) {
            match self.plex.download(key, token).await {
                Ok(bytes) => dialogue::convert(bytes).await.ok(),
                Err(_) => None,
            }
        } else if let (Some(part), Some(index)) = (item.part(), stream.index) {
            let local = part.file.as_deref().map(|file| self.config.local_path(file));
            match local {
                Some(path) if path.exists() => dialogue::extract_local(&path, index).await.ok(),
                _ => match part.key.as_deref().and_then(|key| self.plex.file_request(key, token)) {
                    Some(request) => match request.send().await {
                        Ok(response) if response.status().is_success() => dialogue::extract_streamed(response, index).await.ok(),
                        _ => None,
                    },
                    None => None,
                },
            }
        } else {
            None
        };
        let lines = srt.map(|text| dialogue::parse_srt(&text)).unwrap_or_default();
        let segments = segments::make(&item.plex_markers(), &item.plex_chapters(), item.duration.unwrap_or(0));
        let mut story = dialogue::story(lines, &segments);
        story.truncate(MAX_LINES);
        story
    }

    /// The names a summary of this show may use: the cast's characters and the actors.
    async fn roster(&self, item: &Item, token: &str) -> String {
        let show = match item.grandparent_rating_key.as_deref() {
            Some(key) => self.plex.item(key, token).await.ok(),
            None => None,
        };
        let roles = show.as_ref().map_or(&item.roles, |show| &show.roles);
        roles.iter().filter_map(|role| role.role.clone()).chain(roles.iter().map(|role| role.tag.clone())).collect::<Vec<_>>().join(", ")
    }

    /// A finished episode's summary: kept when written before from the same dialogue, otherwise written, checked and kept.
    pub async fn episode_summary(&self, rating_key: &str, token: &str) -> Result<EpisodeSummary, WriteError> {
        let item = self.plex.item(rating_key, token).await?;
        let synopsis = item.summary.clone().unwrap_or_default();
        let lines = self.dialogue(&item, token).await;
        let transcript = dialogue::transcript(&lines);
        let source = sha(&format!("{synopsis}\n{transcript}"));
        let base = |text: String, grounded: bool| EpisodeSummary { label: item.label(), title: item.title.clone(), text, grounded };
        if let Ok(Some(kept)) = self.store.summary(rating_key, &source, &self.model_key(), PROMPT_VERSION) {
            return Ok(base(kept.text, kept.grounded));
        }
        if lines.is_empty() {
            return Ok(base(synopsis, false));
        }
        let roster = self.roster(&item, token).await;
        let source_text = SummarySource {
            show: item.grandparent_title.clone().unwrap_or_default(),
            label: item.label(),
            title: item.title.clone(),
            synopsis: synopsis.clone(),
            roster,
            lines,
        };
        let (text, grounded) = write_summary(&self.brain, &source_text).await?;
        let summary = Summary { text, grounded };
        let _ = self.store.save_summary(rating_key, &source, &self.model_key(), PROMPT_VERSION, &summary);
        Ok(base(summary.text, grounded))
    }

    /// The finished episodes, oldest first, by season and number.
    async fn finished_items(&self, finished: &[String], token: &str, keep: usize) -> Vec<Item> {
        let mut items = Vec::new();
        for key in finished.iter().rev().take(keep * 2) {
            if let Ok(item) = self.plex.item(key, token).await {
                items.push(item);
            }
        }
        items.sort_by_key(|item| (item.parent_index.unwrap_or(0), item.index.unwrap_or(0)));
        let skip = items.len().saturating_sub(keep);
        items.into_iter().skip(skip).collect()
    }

    /// A Previously On from the summaries of the most recent finished episodes.
    pub async fn recap(&self, finished: &[String], token: &str, language: &str) -> Result<Recap, WriteError> {
        let items = self.finished_items(finished, token, RECAP_EPISODES).await;
        if items.is_empty() {
            return Err(WriteError::NothingWatched);
        }
        let mut summaries = Vec::new();
        for item in &items {
            summaries.push(self.episode_summary(&item.rating_key, token).await?);
        }
        let based_on: Vec<String> = summaries.iter().map(|summary| summary.label.clone()).collect();
        let grounded = summaries.iter().all(|summary| summary.grounded);
        let sources = summaries.iter().map(|summary| format!("{} \"{}\": {}", summary.label, summary.title, summary.text)).collect::<Vec<_>>().join("\n");
        let mut text = summaries.last().map(|summary| summary.text.clone()).unwrap_or_default();
        if let Ok(reply) = self.brain.ask_json(RECAP_SYSTEM, &format!("Episode summaries, oldest first:\n{sources}"), 300).await {
            if let Some(written) = reply["text"].as_str().map(str::trim).filter(|written| !written.is_empty()) {
                if ungrounded_names(written, &sources).is_empty() {
                    text = written.to_string();
                }
            }
        }
        let text = self.translate(text, language).await;
        Ok(Recap { text, based_on, grounded, generated: true, model: self.model_key() })
    }

    /// An answer from the current episode's dialogue before the playhead and the finished episodes' summaries.
    pub async fn answer(
        &self,
        rating_key: &str,
        playhead_ms: u64,
        finished: &[String],
        question: &str,
        token: &str,
        language: &str,
    ) -> Result<Answer, WriteError> {
        let item = self.plex.item(rating_key, token).await?;
        let mut lines = self.dialogue(&item, token).await;
        lines.retain(|line| line.start_ms <= playhead_ms);
        let mut summaries = Vec::new();
        for earlier in self.finished_items(finished, token, ANSWER_EPISODES).await {
            if earlier.rating_key != item.rating_key {
                summaries.push(self.episode_summary(&earlier.rating_key, token).await?);
            }
        }
        let earlier = summaries.iter().map(|summary| format!("{} \"{}\": {}", summary.label, summary.title, summary.text)).collect::<Vec<_>>().join("\n");
        let show = match item.grandparent_rating_key.as_deref() {
            Some(key) => self.plex.item(key, token).await.ok(),
            None => None,
        };
        let context = format!(
            "Show: {} ({})\nEarlier episodes:\n{earlier}\nNow watching {} \"{}\", paused at {}. Its dialogue so far:\n{}",
            item.grandparent_title.clone().unwrap_or_default(),
            show.and_then(|show| show.summary).unwrap_or_default(),
            item.label(),
            item.title,
            dialogue::timestamp(playhead_ms),
            dialogue::transcript(&lines)
        );
        let question: String = question.chars().take(500).collect();
        let mut feedback = String::new();
        for _ in 0..2 {
            let reply = self.brain.ask_json(ANSWER_SYSTEM, &format!("{context}\n\nQuestion: {question}{feedback}"), 300).await?;
            let Some(text) = reply["text"].as_str().map(str::trim).filter(|text| !text.is_empty()) else { continue };
            let names = ungrounded_names(text, &format!("{context}\n{question}"));
            if names.is_empty() {
                let text = self.translate(text.to_string(), language).await;
                return Ok(Answer { text, grounded: true, model: self.model_key() });
            }
            feedback = format!("\n\nThese names are not in the context: {}. Answer again from the context only.", names.join(", "));
        }
        let fallback = self.translate("I can't tell from what you've watched so far.".into(), language).await;
        Ok(Answer { text: fallback, grounded: false, model: self.model_key() })
    }

    /// The text in the device's language; English, or any failure, leaves it as it is.
    async fn translate(&self, text: String, language: &str) -> String {
        let Some(name) = language_name(language) else { return text };
        match self.brain.ask_json(TRANSLATE_SYSTEM, &format!("Language: {name}\nText: {text}"), 600).await {
            Ok(reply) => reply["text"].as_str().map(str::trim).filter(|translated| !translated.is_empty()).map(String::from).unwrap_or(text),
            Err(_) => text,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plex::{Media, Part, Stream};

    fn item_with(streams: Vec<Stream>) -> Item {
        Item { media: vec![Media { parts: vec![Part { streams, ..Part::default() }] }], ..Item::default() }
    }

    fn subtitle(id: u64, codec: &str, language: &str) -> Stream {
        Stream { id, stream_type: 3, codec: Some(codec.into()), language_code: Some(language.into()), ..Stream::default() }
    }

    #[test]
    fn picks_english_text_subtitles_over_pictures_and_other_languages() {
        let item = item_with(vec![subtitle(1, "pgs", "eng"), subtitle(2, "ass", "jpn"), subtitle(3, "srt", "eng")]);
        assert_eq!(pick_stream(&item, "en").map(|s| s.id), Some(3));
        assert_eq!(pick_stream(&item, "ja").map(|s| s.id), Some(2));
        assert!(pick_stream(&item_with(vec![subtitle(1, "pgs", "eng")]), "en").is_none());
    }

    #[test]
    fn knows_the_app_languages() {
        assert_eq!(language_name("ja"), Some("Japanese"));
        assert_eq!(language_name("zh-Hant"), Some("Traditional Chinese"));
        assert_eq!(language_name("en"), None);
    }
}
