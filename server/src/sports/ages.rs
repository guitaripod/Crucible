//! Keeping research away from anything that involves someone under 18. A file whose name says or suggests it is
//! refused before any search. After research, every sentence the record or a page read gives that mentions a young
//! age, minors, school or a birth date is put to the model, told which work it is, ten at a time, to say whether it
//! means someone in that work was under 18; each sentence it counts is asked about again on its own, and a sentence
//! counted both times keeps the work from being written. Words alone cannot tell "If you are under 18, leave this
//! site" or "a 16-year-old single malt" from a performer's age, so the net is wide and the model judges what it
//! catches. Measured on Nemotron 3.5 Bolt with 55 sentences that give someone an age under 18 and 42 that do not
//! (age gates, adult ages, counts, objects): one sentence alone, it counted 54 of the 55 and none of the 42.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use super::work::WorkRecord;
use crate::brain::{Brain, BrainError};

const YOUNG: &str = r"(?:[1-9]|1[0-7]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen)";

/// Words that say or suggest someone is under 18, on their own: what a file name is refused for.
static UNDERAGE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\bunder[\s-]*(?:the\s+age\s+of\s+)?(?:18|eighteen)\b|\bunder-?age(?:d)?\b|\bminors\b|\bchild(?:ren)?\b|\bpre-?teens?\b|\bjail-?bait\b|\blol(?:i|ita)\b|\bschool\s?girls?\b|\bschool\s?boys?\b|\bhigh[\s-]school(?:ers?)?\b|\bjunior[\s-]high\b|\bmiddle[\s-]school\b",
    )
    .expect("underage pattern")
});
/// An age under 18 before "years old" or after "aged" or "age of", or a teenage age after "was", "is" or "turned", with
/// the word after it so a count ("was 15 minutes long") is told apart.
static YOUNG_AGE: LazyLock<Regex> = LazyLock::new(|| {
    let teen = r"(?:1[0-7]|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen)";
    Regex::new(&format!(
        r"(?i)\b{YOUNG}\s*(?:-|\s)?(?:years?|yrs?)[\s-]*old\b|\b{YOUNG}\s*(?:yo|y/o)\b|\b(?:aged?|at\s+age|age\s+of)\s+{YOUNG}\b|\b(?:was|were|is|being|turned|only|just)\s+(?:only\s+|just\s+)?{teen}(?:\s*$|[\s,.;)!?]+(\w*)(?:\s+(\w+))?)"
    ))
    .expect("young age pattern")
});
/// "a minor" as a person, with the word after it, which tells "a minor at the time" from "a minor discrepancy".
static A_MINOR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(?:a|the)\s+minor\b(?:\s+(\w+))?").expect("a minor pattern"));

/// What makes a sentence worth putting to the model: words for someone young, minors or school, an age said against
/// 18, a birth date, or a number under 18 with a word that can make it an age. Wide on purpose; the model judges.
static MENTION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\bunder[\s-]*(?:the\s+)?(?:age\s+(?:of\s+)?)?(?:18|eighteen)\b|\bunder[\s-]*aged?\b|\bminors?\b|\bchild(?:ren|hood|ish)?\b|\bkids?\b|\bschool\s?(?:girl|boy|kid)s?\b|\b(?:high|junior[\s-]high|middle|grade|elementary|primary)[\s-]?school(?:ers?)?\b|\bin\s+school\b|\b(?:[1-9]|1[0-2])(?:st|nd|rd|th)\s+grade\b|\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth)\s+grade\b|\b(?:pre|early|young)[\s-]?teens?\b|\bjail-?bait\b|\blol(?:i|ita)\b|\bnot\s+(?:yet\s+)?(?:turned\s+)?(?:18|eighteen)\b|\bnot\s+(?:yet\s+)?(?:an?\s+)?adults?\b|\b(?:adulthood|majority|consent)\b|\blegal\s+age\b|\bcsam\b|\bborn\b|\bbirth(?:day|date|\s+date|\s+year)?\b|\bd\.?o\.?b\b",
    )
    .expect("mention pattern")
});
/// A number under 18, in digits or words.
static YOUNG_NUMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(&format!(r"(?i)\b{YOUNG}\b")).expect("young number pattern"));
/// A word that can make a number an age.
static AGE_CUE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:years?|yrs?|y\.?\s?o|y/o|old|aged?|ages|turned|turning|teens?|teenage(?:d|r|rs)?|girl|boy|at\s+the\s+time|when|filmed|shot|debut(?:ed)?|first|began|started|looks?|looked|makes?|made|barely|still|younger|youngest)\b",
    )
    .expect("age cue pattern")
});

/// Sentences put to the model in one question; a work with more is asked in several. Past about ten a model starts to
/// pass over sentences in a long list.
const PER_QUESTION: usize = 10;
/// Questions asked for one work at most; a work with still more sentences is refused rather than read in part.
const QUESTIONS: usize = 16;
/// Words kept either side of what a sentence was caught for, so a long run of menu text stays short.
const AROUND: usize = 24;

/// The words in `text` that say or suggest someone is under 18, with a few words around them: what a file's name and
/// folder are refused for before research.
pub fn name_hint(text: &str) -> Option<String> {
    let found = UNDERAGE.find(text).map(|found| found.range()).or_else(|| age_said(text))?;
    Some(around(text, found, 6))
}

/// Where words give someone an age under 18 ("aged 16", "17 years old", "was seventeen at the time") or call a person
/// "a minor". A teenage number followed by a unit or a count ("was 15 minutes long", "is 12 out of 20") is not an age.
fn age_said(text: &str) -> Option<std::ops::Range<usize>> {
    const COUNTS: [&str; 25] = [
        "minutes", "minute", "min", "mins", "seconds", "hours", "days", "weeks", "months", "scenes", "times", "parts", "episodes", "videos", "clips", "photos",
        "pictures", "pics", "stars", "points", "percent", "out", "of", "gb", "inches",
    ];
    const YEARS: [&str; 4] = ["years", "year", "yrs", "yr"];
    const PERSON_FOLLOWS: [&str; 16] =
        ["", "at", "when", "who", "was", "were", "is", "and", "or", "in", "during", "then", "appearing", "performing", "aged", "under"];
    let next = |found: &regex::Captures| found.get(1).map(|word| word.as_str().to_lowercase());
    let whole = |found: regex::Captures| found.get(0).map(|whole| whole.range());
    YOUNG_AGE
        .captures_iter(text)
        .find(|found| match next(found) {
            Some(word) if YEARS.contains(&word.as_str()) => found.get(2).is_some_and(|after| after.as_str().eq_ignore_ascii_case("old")),
            Some(word) => !COUNTS.contains(&word.as_str()),
            None => true,
        })
        .and_then(whole)
        .or_else(|| A_MINOR.captures_iter(text).find(|found| next(found).is_none_or(|word| PERSON_FOLLOWS.contains(&word.as_str()))).and_then(whole))
}

/// The text of `range` with up to `words` words on either side, on one line.
fn around(text: &str, range: std::ops::Range<usize>, words: usize) -> String {
    let before: Vec<&str> = text[..range.start].split_whitespace().rev().take(words).collect();
    let after: Vec<&str> = text[range.end..].split_whitespace().take(words).collect();
    before.into_iter().rev().chain(std::iter::once(&text[range])).chain(after).collect::<Vec<_>>().join(" ")
}

/// The sentences of a page's text. A line break inside a sentence (the next line goes on in lower case or with a
/// number) is a space,
/// and a full stop ends a sentence only before a capital or a line, so "16 yrs. old" and "y.o." stay whole.
pub fn sentences(text: &str) -> Vec<String> {
    let mut sentences = Vec::new();
    let mut current = String::new();
    let chars: Vec<char> = text.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        let character = chars[index];
        let rest = chars[index + 1..].iter().skip_while(|next| next.is_whitespace() && **next != '\n');
        let next_visible = rest.clone().find(|next| !next.is_whitespace()).copied();
        let ends = match character {
            '\n' => !next_visible.is_some_and(|next| next.is_lowercase() || next.is_numeric()),
            '|' | '•' | '·' => true,
            '.' | '!' | '?' => {
                let followed_by_space = chars.get(index + 1).is_none_or(|next| next.is_whitespace());
                followed_by_space
                    && next_visible.is_none_or(|next| {
                        next.is_uppercase()
                            || next.is_numeric()
                            || next == '"'
                            || next == '\''
                            || chars[index + 1..].iter().take_while(|next| next.is_whitespace()).any(|next| *next == '\n')
                    })
            }
            _ => false,
        };
        if character == '\n' && !ends {
            current.push(' ');
        } else if !matches!(character, '|' | '•' | '·') || !ends {
            current.push(character);
        }
        if ends {
            let sentence = current.split_whitespace().collect::<Vec<_>>().join(" ");
            if !sentence.is_empty() {
                sentences.push(sentence);
            }
            current.clear();
        }
        index += 1;
    }
    let sentence = current.split_whitespace().collect::<Vec<_>>().join(" ");
    if !sentence.is_empty() {
        sentences.push(sentence);
    }
    sentences
}

/// The part of a sentence worth putting to the model, when it mentions a young age, minors, school or a birth date.
pub fn mention(sentence: &str) -> Option<String> {
    if let Some(found) = MENTION.find(sentence) {
        return Some(around(sentence, found.range(), AROUND));
    }
    let number = YOUNG_NUMBER.find(sentence)?;
    AGE_CUE.is_match(sentence).then(|| around(sentence, number.range(), AROUND))
}

/// Every sentence to put to the model for a work: from its record's own words and from each page read, with where it
/// was read, each sentence once.
pub fn mentions(record: &WorkRecord, pages: &[(String, String)]) -> Vec<(String, String)> {
    let own =
        [record.title.as_str(), record.series.as_str(), record.studio.as_str(), &record.genres.join(", "), record.summary.as_str(), record.notes.as_str()];
    let mut seen = BTreeSet::new();
    let mut found = Vec::new();
    let read = std::iter::once(("the research's own record".to_string(), own.join(". "))).chain(pages.iter().cloned());
    for (source, text) in read {
        for sentence in sentences(&text) {
            if let Some(part) = mention(&sentence) {
                if seen.insert(part.to_lowercase()) {
                    found.push((source.clone(), part));
                }
            }
        }
    }
    found
}

const JUDGE: &str = "You protect a private film library from anything involving children. Each numbered sentence was found on a web page read while identifying one adult film or scene. For EVERY sentence, decide whether it says or suggests that a person who may appear in this work was under 18 when it was made.

For each sentence, first find the age or status it gives a PERSON, if any, then decide:
- yes: a person's age under 18 at the time (digits or words: \"16 y.o.\", \"sixteen at filming\", \"debut at 16\", \"16 years of age\"); a person called a minor, a child, underage, not yet 18 or not an adult; a person in school below college (high school, ninth grade); a birth year or date that makes the person under 18 on the work's date; a person who looks under 18; minors or children in this work.
- no: ages of 18 or more; a site's age gate, warnings or rules for visitors or members (\"users must be 13\", \"if you are under 18, leave\"); laws and ages of consent; ages of companies, sites, labels, objects or drinks; durations, sizes, prices, ratings, counts, scene numbers and dates; people named in the sentence who are not in this work.
A sentence about \"she\", \"he\", \"the performer\", \"the actress\" or \"the girl\" without a name may be about someone in this work, so judge it as such.
If a sentence gives a person an age or status you cannot place, answer yes.

Reply only with JSON, one entry for every sentence, by its number: {\"answers\": [{\"n\": 1, \"age\": the person's age in years or null, \"answer\": \"yes\" or \"no\"}, {\"n\": 2, ...}, ...]}.";

/// Puts `mentions` to the model, told which work they are about, ten at a time, and asks again about each sentence it
/// counts on its own, which it judges more surely: the first sentence counted both times is given back with where it
/// was read, as saying someone in the work was under 18. A reply that cannot be read is an error, so the work is
/// researched again later rather than written unchecked.
pub async fn judged(brain: &Brain, record: &WorkRecord, mentions: &[(String, String)]) -> Result<Option<String>, BrainError> {
    if mentions.len() > PER_QUESTION * QUESTIONS {
        return Ok(Some(format!("{} sentences on its pages mention ages, too many to check", mentions.len())));
    }
    let work = describe(record);
    let batches = mentions.chunks(PER_QUESTION).map(|batch| ask(brain, &work, batch));
    let answered = futures_util::future::try_join_all(batches).await?;
    for (batch, counted) in mentions.chunks(PER_QUESTION).zip(answered) {
        for index in counted {
            let (source, sentence) = &batch[index];
            if ask(brain, &work, std::slice::from_ref(&batch[index])).await?.contains(&0) {
                return Ok(Some(format!("{} says \"{sentence}\"", host(source))));
            }
        }
    }
    Ok(None)
}

/// The positions of the sentences of `batch` the model counts; a sentence it leaves out of its answer counts.
async fn ask(brain: &Brain, work: &str, batch: &[(String, String)]) -> Result<Vec<usize>, BrainError> {
    let listed: Vec<String> = batch.iter().enumerate().map(|(index, (source, sentence))| format!("{}. [{}] {sentence}", index + 1, host(source))).collect();
    let reply = brain.ask_json(JUDGE, &format!("{work}\n\nSentences:\n{}", listed.join("\n")), 120 * batch.len() as u32 + 200).await?;
    counted(&reply, batch.len())
}

/// The work as the model is told it: title, series, studio, date and the people in it.
fn describe(record: &WorkRecord) -> String {
    let date = if record.date.is_empty() { record.year.map(|year| year.to_string()).unwrap_or_else(|| "unknown".into()) } else { record.date.clone() };
    format!(
        "The work: {}{}, by {}, released {date}. People in it: {}.",
        if record.title.is_empty() { &record.series } else { &record.title },
        if record.series.is_empty() || record.series == record.title { String::new() } else { format!(" ({})", record.series) },
        if record.studio.is_empty() { "an unknown studio" } else { &record.studio },
        if record.people.is_empty() { "not known".to_string() } else { record.people.join(", ") }
    )
}

/// The positions (from 0) of the sentences of `asked` the reply counts, by the numbers it gives them: a "yes", or a
/// sentence the reply does not answer. A reply without its list of answers is an error.
fn counted(reply: &Value, asked: usize) -> Result<Vec<usize>, BrainError> {
    let answers = reply.get("answers").and_then(Value::as_array).ok_or(BrainError::Shape)?;
    let number = |answer: &Value| answer.get("n").and_then(|n| n.as_u64().or_else(|| n.as_str().and_then(|text| text.trim().parse().ok())));
    let said: std::collections::BTreeMap<u64, bool> = answers
        .iter()
        .filter_map(|answer| {
            Some((number(answer)?, answer.get("answer").and_then(Value::as_str).is_none_or(|word| !word.trim().to_lowercase().starts_with('n'))))
        })
        .collect();
    Ok((1..=asked as u64).filter(|n| said.get(n).copied().unwrap_or(true)).map(|n| n as usize - 1).collect())
}

/// The host of a page address, or the words as given for a source that is not a page.
fn host(source: &str) -> String {
    reqwest::Url::parse(source)
        .ok()
        .and_then(|url| url.host_str().map(|host| host.trim_start_matches("www.").to_string()))
        .unwrap_or_else(|| source.to_string())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::json;

    use super::*;
    use crate::brain::testing::{start, Received};
    use crate::config::Model;

    #[test]
    fn names_are_refused_for_what_they_say() {
        for young in ["Schoolgirl Scene 720p", "a 15yo", "aged 16", "was a minor at the time", "under-age", "Starring two minors."] {
            assert!(name_hint(young).is_some(), "{young}");
        }
        for adult in ["BigTitsInSports - 2010.09.29 Rachel Starr, Julia Ann 1080p", "Minor date discrepancy", "The scene was 15 minutes long."] {
            assert!(name_hint(adult).is_none(), "{adult}");
        }
    }

    #[test]
    fn sentences_keep_abbreviations_and_wrapped_lines_whole() {
        assert_eq!(sentences("Lords was 16 yrs. old at the time. She left."), vec!["Lords was 16 yrs. old at the time.", "She left."]);
        assert_eq!(sentences("She was under\n18 when filmed.\nCategories"), vec!["She was under 18 when filmed.", "Categories"]);
        assert_eq!(sentences("Performer, 16 y.o., filmed in 2010 | Teen (18+) | MILF"), vec!["Performer, 16 y.o., filmed in 2010", "Teen (18+)", "MILF"]);
    }

    #[test]
    fn the_net_catches_every_way_of_saying_an_age_under_18() {
        for said in [
            "She was under 18 when the video was shot.",
            "She had not yet turned 18 when the scene was shot.",
            "She was under age when filmed.",
            "She was 16 years of age when filmed.",
            "Lords was 16 yrs. old at the time of filming.",
            "She made her debut at 16.",
            "She first filmed at sixteen.",
            "Age at filming: 17.",
            "Performer, 16 at the time of filming, was named in the case.",
            "Minor at the time of filming.",
            "Two minors appeared in the scene, according to the police report.",
            "The film featured children, police said.",
            "Born in 1992, she was filming in 2009.",
            "The producer knowingly filmed a 16-year-old.",
            "She was below the legal age when filmed.",
            "She was still a high school student when the scene was shot.",
            "The actress was in the ninth grade when filmed.",
            "She had not reached adulthood when the film was made.",
            "She was not an adult when the film was made.",
            "She looks 16 in this scene.",
            "She was in her early teens.",
            "The girl was just a girl of 15 when filmed.",
            "Ages 14 and 16 at the time of filming.",
            "Court papers show she was barely 17.",
        ] {
            assert!(sentences(said).iter().any(|sentence| mention(sentence).is_some()), "{said}");
        }
        for plain in ["Rachel Starr and Julia Ann star in this Brazzers scene.", "Released 2010-09-29 in 1080p.", "Teen (18+)"] {
            assert!(mention(plain).is_none(), "{plain}");
        }
    }

    fn record() -> WorkRecord {
        WorkRecord {
            identified: true,
            title: "J.A.R.S".into(),
            series: "Big Tits In Sports".into(),
            studio: "Brazzers".into(),
            date: "2010-09-29".into(),
            people: vec!["Rachel Starr".into(), "Julia Ann".into(), "Keiran Lee".into()],
            summary: "Two coaches meet a player after practice.".into(),
            sources: vec!["https://www.data18.com/scenes/144514".into()],
            ..WorkRecord::default()
        }
    }

    #[test]
    fn the_record_and_each_page_give_their_mentions_once() {
        let pages = vec![
            ("https://www.data18.com/scenes/144514".to_string(), "If you are under 18 years of age, leave now. Rachel Starr was born in 1985.".to_string()),
            ("https://fantasyhd.com/video".to_string(), "If you are under 18 years of age, leave now.".to_string()),
        ];
        let found = mentions(&record(), &pages);
        assert_eq!(found.len(), 2, "{found:?}");
        assert_eq!(found[0].0, "https://www.data18.com/scenes/144514");
    }

    #[test]
    fn an_answer_counts_by_its_number_and_a_missing_one_counts() {
        let reply = json!({"answers": [{"n": 2, "age": 16, "answer": "yes"}, {"n": 1, "age": null, "answer": "no"}, {"n": "4", "answer": "No"}]});
        assert_eq!(counted(&reply, 4).unwrap(), vec![1, 2]);
        assert!(counted(&json!({"under_18": []}), 2).is_err());
    }

    async fn judge(batch: Value, alone: Value) -> Result<Option<String>, BrainError> {
        let service = start(
            &["bolt"],
            Arc::new(move |received: &[Received]| {
                let asked = received.last().map(|last| last.body.to_string()).unwrap_or_default();
                let reply = if asked.contains("2. [") { batch.clone() } else { alone.clone() };
                (200, Vec::new(), json!({"choices": [{"message": {"content": reply.to_string()}}]}))
            }),
        )
        .await;
        let brain = Brain::new(Model { url: service.url.clone(), name: "bolt".into(), context: 65_536 });
        let found = vec![
            ("https://fantasyhd.com/video".to_string(), "If you are under 18 years of age, leave now.".to_string()),
            ("https://www.iafd.com/person".to_string(), "She was 16 when this was filmed.".to_string()),
        ];
        judged(&brain, &record(), &found).await
    }

    #[tokio::test]
    async fn a_sentence_counts_only_when_the_model_counts_it_again_on_its_own() {
        let no = json!({"answers": [{"n": 1, "answer": "no"}, {"n": 2, "answer": "no"}]});
        let second = json!({"answers": [{"n": 1, "answer": "no"}, {"n": 2, "age": 16, "answer": "yes"}]});
        let yes_alone = json!({"answers": [{"n": 1, "age": 16, "answer": "yes"}]});
        let no_alone = json!({"answers": [{"n": 1, "answer": "no"}]});
        assert_eq!(judge(no.clone(), yes_alone.clone()).await.unwrap(), None);
        assert_eq!(judge(second.clone(), yes_alone).await.unwrap().as_deref(), Some("iafd.com says \"She was 16 when this was filmed.\""));
        assert_eq!(judge(second, no_alone).await.unwrap(), None);
        assert!(judge(json!({"verdict": "fine"}), no).await.is_err());
    }
}
