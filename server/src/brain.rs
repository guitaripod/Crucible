//! The model, reached through any OpenAI-compatible endpoint (llama-swap, Ollama, LM Studio), and the checks that
//! keep what it writes grounded: every name it uses must appear in what it was given, and every sentence must be
//! supported by the lines it cites.

use std::collections::BTreeSet;
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::Semaphore;

use crate::config::Model;

#[derive(Debug, thiserror::Error)]
pub enum BrainError {
    #[error("the model at {0} did not answer: {1}")]
    Unreachable(String, String),
    #[error("the model answered {0}: {1}")]
    Status(u16, String),
    #[error("the model's answer was not the JSON asked for")]
    Shape,
}

#[derive(Clone)]
pub struct Brain {
    pub model: Model,
    http: reqwest::Client,
    calls: Arc<Semaphore>,
}

#[derive(Deserialize)]
struct Completion {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: Message,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    #[serde(default)]
    content: Option<String>,
}

/// Tokens a reasoning model may spend thinking before its answer, on top of what the answer needs, at most a quarter
/// of the window.
const THINKING_ALLOWANCE: u32 = 4096;
/// Tokens kept for the instructions, the synopsis and the roster around the dialogue.
const PROMPT_RESERVE: u32 = 1800;

/// A model the endpoint lists, with the context window it states when it states one (llama-swap's "· 256K").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listed {
    pub id: String,
    pub context: Option<u32>,
}

static CONTEXT_SIZE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(\d{1,4})\s*K\b").expect("context pattern"));

/// The window a model description names, such as "Gemma 4 26B · llama.cpp · UD-Q4_K_M · 8K".
pub fn context_in(description: &str) -> Option<u32> {
    CONTEXT_SIZE.captures_iter(description).last().and_then(|captures| captures[1].parse::<u32>().ok()).map(|thousands| thousands * 1024)
}

/// Two calls in flight per model host, so a recap never queues behind a whole season of background summaries.
const CALLS_IN_FLIGHT: usize = 2;

impl Brain {
    pub fn new(model: Model) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(300)).connect_timeout(Duration::from_secs(5)).build().expect("an HTTP client builds");
        Brain { model, http, calls: Arc::new(Semaphore::new(CALLS_IN_FLIGHT)) }
    }

    /// The models the endpoint lists, to check it answers and has the configured one.
    pub async fn models(&self) -> Result<Vec<String>, BrainError> {
        Ok(self.listed().await?.into_iter().map(|listed| listed.id).collect())
    }

    /// The models the endpoint lists, with their context windows when it states them.
    pub async fn listed(&self) -> Result<Vec<Listed>, BrainError> {
        let url = format!("{}/models", self.model.url.trim_end_matches('/'));
        let response =
            self.http.get(&url).timeout(Duration::from_secs(10)).send().await.map_err(|error| BrainError::Unreachable(url.clone(), error.to_string()))?;
        let status = response.status();
        let body: Value = response.json().await.map_err(|_| BrainError::Shape)?;
        if !status.is_success() {
            return Err(BrainError::Status(status.as_u16(), body.to_string()));
        }
        Ok(body["data"]
            .as_array()
            .map(|models| {
                models
                    .iter()
                    .filter_map(|model| {
                        let id = model["id"].as_str()?.to_string();
                        let context = model["description"].as_str().and_then(context_in).or_else(|| model["context_length"].as_u64().map(|n| n as u32));
                        Some(Listed { id, context })
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    fn thinking_allowance(&self) -> u32 {
        THINKING_ALLOWANCE.min(self.model.context / 4)
    }

    /// How many characters of dialogue fit beside the prompt and the answer, at about three characters a token.
    pub fn dialogue_budget(&self, answer_tokens: u32) -> usize {
        let room = self.model.context.saturating_sub(PROMPT_RESERVE + answer_tokens + self.thinking_allowance());
        room as usize * 3
    }

    /// One chat turn at low temperature, answered as a JSON object.
    pub async fn ask_json(&self, system: &str, user: &str, max_tokens: u32) -> Result<Value, BrainError> {
        let _permit = self.calls.acquire().await.expect("the semaphore stays open");
        let url = format!("{}/chat/completions", self.model.url.trim_end_matches('/'));
        let body = json!({
            "model": self.model.name,
            "temperature": 0.2,
            "max_tokens": max_tokens + self.thinking_allowance(),
            "response_format": {"type": "json_object"},
            "chat_template_kwargs": {"enable_thinking": false},
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        });
        let response = self.http.post(&url).json(&body).send().await.map_err(|error| BrainError::Unreachable(url.clone(), error.to_string()))?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            return Err(BrainError::Status(status.as_u16(), text.chars().take(300).collect()));
        }
        let completion: Completion = response.json().await.map_err(|_| BrainError::Shape)?;
        let choice = completion.choices.into_iter().next().ok_or(BrainError::Shape)?;
        let content = choice.message.content.unwrap_or_default();
        first_json_object(&content).ok_or_else(|| {
            tracing::warn!(finish = ?choice.finish_reason, length = content.len(), start = %content.chars().take(160).collect::<String>(), "the model's reply held no JSON");
            BrainError::Shape
        })
    }
}

/// The first JSON object in a model's reply, which may wrap it in a code fence or a sentence.
pub fn first_json_object(text: &str) -> Option<Value> {
    let start = text.find('{')?;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, character) in text[start..].char_indices() {
        if in_string {
            match character {
                '\\' if !escaped => escaped = true,
                '"' if !escaped => in_string = false,
                _ => escaped = false,
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return serde_json::from_str(&text[start..=start + offset]).ok();
                }
            }
            _ => {}
        }
    }
    None
}

static TRAILING_TIME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*[\[(]\d{1,2}:\d{2}(:\d{2})?[\])]\s*$").expect("time pattern"));

static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{Lu}][\p{L}\p{M}'’\-]*").expect("word pattern"));
static SENTENCE_START: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(^|[.!?…]["”’)]?\s+)$"#).expect("sentence start pattern"));

/// Capitalised words that begin sentences in English and are not names.
const COMMON: &[&str] = &[
    "a",
    "after",
    "all",
    "also",
    "an",
    "and",
    "as",
    "at",
    "back",
    "before",
    "both",
    "but",
    "despite",
    "during",
    "each",
    "eventually",
    "even",
    "everyone",
    "finally",
    "for",
    "from",
    "he",
    "her",
    "his",
    "however",
    "i",
    "if",
    "in",
    "it",
    "its",
    "later",
    "meanwhile",
    "now",
    "on",
    "once",
    "one",
    "she",
    "so",
    "still",
    "the",
    "their",
    "then",
    "there",
    "they",
    "this",
    "though",
    "to",
    "together",
    "unable",
    "upon",
    "when",
    "while",
    "with",
    "without",
    "yet",
    "episode",
    "previously",
    "season",
    "s",
    "e",
];

/// The names in `text` that appear nowhere in `context`: a capitalised word in mid-sentence, or one that starts a
/// sentence and is not a common English word. Context words are matched ignoring case.
pub fn ungrounded_names(text: &str, context: &str) -> Vec<String> {
    let known: BTreeSet<String> = WORD.find_iter(context).map(|word| fold(word.as_str())).chain(context.split_whitespace().map(fold)).collect();
    let mut missing = BTreeSet::new();
    for word in WORD.find_iter(text) {
        let folded = fold(word.as_str());
        if folded.len() < 2 || COMMON.contains(&folded.as_str()) || known.contains(&folded) {
            continue;
        }
        let at_start = SENTENCE_START.is_match(&text[..word.start()]);
        if at_start && !text[word.end()..].trim_start().starts_with(|c: char| c.is_uppercase()) && is_plain_word(&folded) {
            continue;
        }
        missing.insert(word.as_str().trim_end_matches(['\'', '’', '-']).to_string());
    }
    missing.into_iter().collect()
}

fn fold(word: &str) -> String {
    word.trim_matches(|c: char| !c.is_alphanumeric()).trim_end_matches("'s").trim_end_matches("’s").to_lowercase()
}

/// A word that starts a sentence is taken as a name only when it does not look like an English word: names from
/// anime rosters (Goku, Vegeta, Beerus) end in vowels or use letters English words rarely start with.
fn is_plain_word(folded: &str) -> bool {
    folded.ends_with("ed") || folded.ends_with("ing") || folded.ends_with("ly") || folded.ends_with("s")
}

/// One sentence of a summary with the moment it rests on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cited {
    pub text: String,
    pub at_ms: Option<u64>,
}

/// The `{"sentences":[{"text","at"}]}` a summary prompt asks for.
pub fn cited_sentences(value: &Value) -> Vec<Cited> {
    value["sentences"]
        .as_array()
        .map(|sentences| {
            sentences
                .iter()
                .filter_map(|sentence| {
                    let text = TRAILING_TIME.replace(sentence["text"].as_str()?.trim(), "").trim().to_string();
                    (!text.is_empty()).then(|| Cited { text, at_ms: sentence["at"].as_str().and_then(parse_timestamp) })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// "12:34" or "1:02:03" as milliseconds.
pub fn parse_timestamp(text: &str) -> Option<u64> {
    let parts: Vec<u64> = text.trim().trim_matches(['[', ']']).split(':').map(|part| part.trim().parse().ok()).collect::<Option<_>>()?;
    let seconds = match parts.as_slice() {
        [minutes, seconds] => minutes * 60 + seconds,
        [hours, minutes, seconds] => (hours * 60 + minutes) * 60 + seconds,
        _ => return None,
    };
    Some(seconds * 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_a_timestamp_the_model_also_wrote_into_the_sentence() {
        let value = serde_json::json!({"sentences": [{"text": "Goku trains. [8:53]", "at": "8:53"}, {"text": "Beerus naps (12:01)"}]});
        assert_eq!(cited_sentences(&value).iter().map(|s| s.text.as_str()).collect::<Vec<_>>(), vec!["Goku trains.", "Beerus naps"]);
    }

    #[test]
    fn finds_the_json_in_a_fenced_reply() {
        let value = first_json_object("Sure!\n```json\n{\"sentences\":[{\"text\":\"Goku {trains}.\",\"at\":\"3:01\"}]}\n```").unwrap();
        let sentences = cited_sentences(&value);
        assert_eq!(sentences, vec![Cited { text: "Goku {trains}.".into(), at_ms: Some(181_000) }]);
        assert!(first_json_object("no json here").is_none());
    }

    #[test]
    fn flags_a_name_the_context_never_mentions() {
        let context = "Goku and Vegeta train on Beerus's planet. Whis watches.";
        assert!(ungrounded_names("Goku trains with Vegeta while Whis watches. Beerus naps.", context).is_empty());
        assert_eq!(ungrounded_names("Goku trains while Mr. Satan cheers.", context), vec!["Mr", "Satan"]);
        assert_eq!(ungrounded_names("Later, Goku meets Hit.", context), vec!["Hit"]);
        assert!(ungrounded_names("Determined, Goku trains harder. Afterwards he rests.", context).is_empty());
    }

    #[test]
    fn reads_the_context_window_from_a_description() {
        assert_eq!(context_in("Gemma 4 26B · llama.cpp · UD-Q4_K_M · 8K"), Some(8192));
        assert_eq!(context_in("Groot 19B · vLLM · NVFP4 · MTP · 256K"), Some(262_144));
        assert_eq!(context_in("no size"), None);
    }

    #[test]
    fn reads_timestamps() {
        assert_eq!(parse_timestamp("[12:34]"), Some(754_000));
        assert_eq!(parse_timestamp("1:02:03"), Some(3_723_000));
        assert_eq!(parse_timestamp("soon"), None);
    }
}
