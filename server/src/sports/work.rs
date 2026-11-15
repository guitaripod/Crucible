//! Files that are not sports: adult films and scenes, and anything else Plex has no agent for (game cinematics,
//! concerts, documentaries, clips). The name is read for what it gives away (a date, a scene number, the words that
//! are only technical), the owner's model researches the work on the web like a sports event, and the record it hands
//! in is checked and written into Plex the same way, with the studio, the series and the people in it.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::record::{parse_date, Desired};
use super::research::{investigate, Step, Took};
use super::web::Web;
use crate::brain::Brain;
use crate::config::Kind;
use crate::converse::{tool, ToolCall};

static EXTENSION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(\.part)?\.(mkv|mp4|m4v|avi|ts|m2ts|mts|mov|wmv|webm|mpg|mpeg|flv|f4v|vob|divx|xvid|3gp|ogv|ogm|iso|rm|rmvb|asf)$")
        .expect("extension pattern")
});
static FULL_DATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b((?:19|20)\d{2})[.\-_ ](0[1-9]|1[0-2])[.\-_ ](0[1-9]|[12]\d|3[01])\b").expect("full date pattern"));
static SHORT_DATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[.\s_-])(\d{2})\.(0[1-9]|1[0-2])\.(0[1-9]|[12]\d|3[01])(?:[.\s_-]|$)").expect("short date pattern"));
static YEAR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(19[5-9]\d|20[0-4]\d)\b").expect("year pattern"));
static PART: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:(sc|scene|scn)\s*\.?\s*(\d{1,2})|(part|pt)\s*\.?\s*(\d{1,2})|(cd|disc|disk)\s*\.?\s*(\d{1,2}))\b").expect("part pattern")
});
static TECHNICAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(\d{3,4}p|4k|web[\s-]?dl|web[\s-]?rip|webrip|hdtv|dvdrip|bdrip|bluray|blu-ray|x26[45]|h[\s.]?26[45]|hevc|avc|xvid|divx|aac|ac3|dts|mp4|split\s+scenes?)\b").expect("technical pattern")
});
/// Tags that are also words in titles ("A Proper Lady", "xXx"), so they count as technical only in capitals.
static SHOUTED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(XXX|PROPER|REPACK|HD|SD|UHD|FHD|INTERNAL|REMUX)\b").expect("shouted pattern"));
/// The release group a scene name ends with after its technical words: "x265-GROUP", "H264-FBB".
static GROUP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(\d{3,4}p|x26[45]|h\.?26[45]|hevc|avc|xvid|divx|aac|ac3|dts|web-?dl|webrip|hdtv|bluray|dvdrip|bdrip|xxx)-[a-z0-9]+$")
        .expect("group pattern")
});
static BRACKETS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[[^\]]*\]|\{[^}]*\}").expect("brackets pattern"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("spaces pattern"));
/// How the note of a file research refused to touch begins.
pub const REFUSED: &str = "Not researched, since something suggests someone in it is under 18";
/// Names and sources that mark a file in a general library as adult, so it is held to the same check.
static ADULT_MARK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bxxx\b|iafd\.com|data18\.com|adultempire\.com|aebn\.(?:com|net)|adultfilmdatabase\.com|freeones\.com|pornhub\.com|brazzers\.com")
        .expect("adult mark pattern")
});

/// This year, by the clock.
fn this_year() -> i32 {
    let days = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_secs() / 86_400).unwrap_or(0);
    1970 + (days as f64 / 365.2425) as i32
}

/// The full year of a two-digit one in a release name: this century unless that would be in the future.
fn century(two_digits: &str, this_year: i32) -> i32 {
    let year = 2000 + two_digits.parse::<i32>().unwrap_or(0);
    if year > this_year {
        year - 100
    } else {
        year
    }
}

/// Whether a scene or part mark comes after some of the name, so a name that starts with one ("SC2 - 01 - The Deal",
/// a game) keeps it as its own.
fn follows_a_title(text: &str, found: &regex::Captures) -> bool {
    let start = found.get(0).map_or(0, |whole| whole.start());
    text[..start].chars().any(char::is_alphanumeric)
}

/// A file name read for what it gives away.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Work {
    pub file_name: String,
    /// The name without its extension, technical words, brackets and the scene or part: "Young Harlots In London".
    pub cleaned: String,
    /// What the copies of one file share, so one research serves them all: its folder, name, date and part. Scenes of
    /// one movie each have their own, since a scene has its own title, people and date.
    pub key: String,
    /// The scene, part or disc the file holds, when the name says: "Scene 2", "Part 1", "Disc 2".
    pub part: Option<String>,
    /// The date the name carries, as YYYY-MM-DD.
    pub date: Option<String>,
    /// The year the name carries, when it carries no whole date.
    pub year: Option<i32>,
    /// The folder the file is in, when it says more than the library's own folder.
    pub folder: Option<String>,
}

impl Work {
    pub fn read(path: &str) -> Work {
        let file_name = path.rsplit(['/', '\\']).next().unwrap_or(path).to_string();
        let folder = path.rsplit(['/', '\\']).nth(1).map(str::to_string).filter(|folder| !folder.is_empty());
        let stem = EXTENSION.replace(&file_name, "").to_string();
        let stem = GROUP.replace(&stem, "$1").to_string();
        let this_year = this_year();
        let date = FULL_DATE
            .captures(&stem)
            .map(|found| format!("{}-{}-{}", &found[1], &found[2], &found[3]))
            .or_else(|| SHORT_DATE.captures(&stem).map(|found| format!("{}-{}-{}", century(&found[1], this_year), &found[2], &found[3])))
            .filter(|date| parse_date(date).is_some());
        let without_dates = SHORT_DATE.replace_all(&FULL_DATE.replace_all(&stem, " "), " ").to_string();
        let year = if date.is_some() {
            None
        } else {
            YEAR.captures_iter(&without_dates).filter_map(|found| found[1].parse::<i32>().ok()).find(|year| *year <= this_year)
        };
        let part = PART.captures_iter(&without_dates).find(|found| follows_a_title(&without_dates, found)).and_then(|found| {
            let (word, number) = if let (Some(_), Some(number)) = (found.get(1), found.get(2)) {
                ("Scene", number)
            } else if let (Some(_), Some(number)) = (found.get(3), found.get(4)) {
                ("Part", number)
            } else {
                ("Disc", found.get(6)?)
            };
            number.as_str().parse::<u32>().ok().map(|number| format!("{word} {number}"))
        });
        let spaced = if without_dates.matches(' ').count() < 2 { without_dates.replace(['.', '_'], " ") } else { without_dates.replace('_', " ") };
        let unbracketed = BRACKETS.replace_all(&spaced, " ").to_string();
        let cut = PART
            .replace_all(&unbracketed, |found: &regex::Captures| if follows_a_title(&unbracketed, found) { " ".to_string() } else { found[0].to_string() })
            .to_string();
        let cut = SHOUTED.replace_all(&TECHNICAL.replace_all(&cut, " "), " ").to_string();
        let cleaned = SPACES
            .replace_all(&cut, " ")
            .trim_matches(|c: char| c.is_whitespace() || matches!(c, '!' | '#' | '-' | '.' | '_' | '(' | ')' | ',' | '+' | '~'))
            .to_string();
        let cleaned = if cleaned.is_empty() { stem.clone() } else { cleaned };
        let key = [
            folder.as_deref().map(super::research::folded).unwrap_or_default(),
            super::research::folded(&cleaned.replace(" - ", " ")),
            date.clone().or_else(|| year.map(|year| year.to_string())).unwrap_or_default(),
            part.clone().unwrap_or_default().to_lowercase(),
        ]
        .join("|");
        Work { file_name, cleaned, key, part, date, year, folder }
    }

    /// Whether the file's name or folder marks it as adult, for a file in a library that is not set to adult.
    pub fn looks_adult(&self) -> bool {
        ADULT_MARK.is_match(&self.file_name) || self.folder.as_deref().is_some_and(|folder| ADULT_MARK.is_match(folder))
    }

    /// What the model is told about the file before it starts.
    pub fn brief(&self, library: &str, added: &str) -> String {
        let mut lines = vec![format!("File name: {}", self.file_name), format!("Name without technical words: {}", self.cleaned)];
        if !library.is_empty() {
            lines.push(format!("Library: {library}"));
        }
        if let Some(folder) = self.folder.as_ref().filter(|folder| !folder.eq_ignore_ascii_case(library)) {
            lines.push(format!("Folder: {folder}"));
        }
        if let Some(date) = &self.date {
            lines.push(format!("The name carries the date {date}."));
        } else if let Some(year) = self.year {
            lines.push(format!("The name carries the year {year}."));
        }
        if let Some(part) = &self.part {
            lines.push(format!("The file holds {part} of the work."));
        }
        if !added.is_empty() {
            lines.push(format!("Added to the library on {added}, so the work came out on or before that day."));
        }
        lines.join("\n")
    }
}

/// What research made of a file that is not sports.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct WorkRecord {
    pub identified: bool,
    pub title: String,
    pub series: String,
    pub part: Option<String>,
    pub studio: String,
    pub date: String,
    pub year: Option<i32>,
    pub people: Vec<String>,
    pub genres: Vec<String>,
    pub summary: String,
    pub poster_url: Option<String>,
    pub sources: Vec<String>,
    pub confidence: String,
    pub notes: String,
}

const GENERAL: &str = "You identify the video files in a private Plex library and research them on the web, so the library can show proper titles, dates, descriptions and artwork. The files are things Plex has no agent for: game cinematics and trailers, concerts, stand-up, documentaries, lectures, music videos, online and home-made videos.

You get one file name with the library and folder it is in. Work like a careful researcher:
1. Read the name. It often carries the work's title, the game, series, tour or channel it belongs to, a number, a date or year, and technical words you ignore.
2. Search to identify what the file is. Prefer official sources: the publisher's, studio's or artist's own site, the wiki of the game or series, Wikipedia, IMDb, the video's own page.
3. Read a page that confirms the title, the date or year, and who made it.
4. Look for artwork on a page you read. Give an image address only if a page you read lists it.
5. Call submit once with the record.

Rules:
- State only what you saw in search results or pages. If you cannot tell what the file is, submit with identified false and say why in notes.
- title is the work's own title without its series, such as \"The Deal\". series is the game, show, album, tour or channel it belongs to, such as \"StarCraft II: Wings of Liberty\"; leave it empty for a work that stands alone.
- part is the work's number or part within its series when the name gives one, such as \"1\" or \"Part 2\".
- studio is who made or published it. people are the main people in it, by name. genres are one to three broad genres.
- summary is one to three plain sentences in English about the work itself, never about the file. No hype, no em dashes.
- date is YYYY-MM-DD when a page gives the day; otherwise leave it empty and give year.
- Keep tool calls purposeful: at most six searches and six page reads. Never repeat a search.";

const ADULT: &str = "You identify adult films and scenes in a private Plex library that belongs to an adult, and research them on the web, so the library can show proper titles, studios, performers, release dates, descriptions and artwork. This is ordinary catalog work, like a film database's.

You get one file name with the library and folder it is in. Work like a careful researcher:
1. Read the name. Release names carry the studio or site, the release date (often as YY.MM.DD), performers' names, the scene's or movie's title, a scene number and technical words you ignore. A site is often written as its initials or run together: btaw is Big Tits At Work, BigTitsInSports is Big Tits In Sports. Spell it out before you search, and search the performer with the site when the name has no title.
2. Search to identify the exact scene or movie. Prefer the studio's own site and adult film databases: IAFD, Data18, Adult Empire, AEBN, Adult Film Database, FreeOnes.
3. Read a page that confirms the title, the studio, the performers and the release date.
4. Artwork: take the scene's or movie's cover or still from a page you read. Give an image address only if that page lists it.
5. Call submit once with the record.

Rules:
- State only what you saw in search results or pages. If you cannot identify the file, submit with identified false and say why in notes.
- Everyone in it must be an adult. If a page you read says anyone in it was under 18, stop and submit with identified false, saying so in notes.
- title is the scene's or movie's own title. series is the movie a scene belongs to, or the site's series for a scene released on its own; leave it empty for a movie that stands alone.
- part is the scene number, such as \"Scene 2\", when the file holds one scene of a movie.
- studio is the studio or site. people are the performers, by their stage names. genres are one to three broad categories.
- summary is one or two sentences describing the scene or movie in neutral, non-graphic words, as a catalog listing would; never explicit, no em dashes.
- date is the release date as YYYY-MM-DD when a page gives it; otherwise leave it empty and give year.
- Keep tool calls purposeful: at most six searches and six page reads. Never repeat a search.";

fn submit() -> Value {
    tool(
        "submit",
        "Hand in the finished record. Call exactly once, at the end.",
        json!({"type": "object", "properties": {
            "identified": {"type": "boolean"},
            "title": {"type": "string"},
            "series": {"type": "string"},
            "part": {"type": ["string", "null"]},
            "studio": {"type": "string"},
            "date": {"type": "string", "description": "YYYY-MM-DD, or empty"},
            "year": {"type": ["integer", "null"]},
            "people": {"type": "array", "items": {"type": "string"}},
            "genres": {"type": "array", "items": {"type": "string"}},
            "summary": {"type": "string"},
            "poster_url": {"type": ["string", "null"]},
            "sources": {"type": "array", "items": {"type": "string"}, "description": "Addresses of the pages that confirm the facts"},
            "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
            "notes": {"type": "string"}},
            "required": ["identified", "title", "summary", "sources", "confidence"]}),
    )
}

/// One name, trimmed, with its runs of spaces closed and its dashes plain.
fn tidy(text: &str) -> String {
    SPACES.replace_all(text.trim(), " ").replace(['—', '–'], "-")
}

impl WorkRecord {
    /// Brings the record to the library's own words: the part the file names wins, dates are real or empty, and
    /// the lists hold distinct, trimmed names.
    pub fn settle(&mut self, work: &Work) {
        self.title = tidy(&self.title);
        self.series = tidy(&self.series);
        self.studio = tidy(&self.studio);
        self.summary = tidy(&self.summary);
        self.part = work.part.clone().or_else(|| self.part.as_deref().map(tidy).filter(|part| !part.is_empty()));
        if parse_date(&self.date).is_none() {
            self.date = work.date.clone().unwrap_or_default();
        }
        if let Some((year, _, _)) = parse_date(&self.date) {
            self.year = Some(year);
        } else if self.year.is_none_or(|year| !(1900..=2200).contains(&year)) {
            self.year = work.year;
        }
        let distinct = |names: &mut Vec<String>, most: usize| {
            let mut seen = BTreeSet::new();
            names.retain(|name| {
                let name = tidy(name);
                !name.is_empty() && seen.insert(name.to_lowercase())
            });
            for name in names.iter_mut() {
                *name = tidy(name);
            }
            names.truncate(most);
        };
        distinct(&mut self.people, 12);
        distinct(&mut self.genres, 3);
        self.confidence = match self.confidence.to_lowercase().as_str() {
            "high" => "high",
            "medium" => "medium",
            _ => "low",
        }
        .into();
    }

    /// The record of a file that is not researched because something suggests someone in it is under 18, saying what.
    pub fn refused(hint: &str) -> WorkRecord {
        WorkRecord { notes: format!("{REFUSED}: {hint}."), ..WorkRecord::default() }
    }

    /// Whether the record's sources are adult film sites, for a file in a library that is not set to adult.
    pub fn looks_adult(&self) -> bool {
        self.sources.iter().any(|source| ADULT_MARK.is_match(source))
    }

    /// What is wrong with an identified record: no title, sources the research never saw, or a date after the file
    /// arrived.
    pub fn problems(&self, known: &BTreeSet<String>, newest: i64) -> Vec<String> {
        if !self.identified {
            return Vec::new();
        }
        let mut problems = Vec::new();
        if self.title.is_empty() && self.series.is_empty() {
            problems.push("Give the work's title.".to_string());
        }
        if self.sources.is_empty() {
            problems.push("Name the pages that confirm the facts in sources.".to_string());
        }
        let unseen: Vec<&String> = self.sources.iter().filter(|source| !super::research::seen_source(known, source)).collect();
        if !unseen.is_empty() {
            problems.push(format!(
                "These sources were not in any search result or page you read: {}. Use only addresses you saw.",
                unseen.iter().map(|source| source.as_str()).collect::<Vec<_>>().join(", ")
            ));
        }
        if let Some((year, month, day)) = parse_date(&self.date) {
            if super::record::days_from_civil(year, month, day) > newest {
                problems.push(format!("The date {} is after the file arrived; give the work's own release date.", self.date));
            }
        }
        problems
    }

    /// The title Plex shows: the work's own title, with the scene or part when the title is the whole work's (a scene
    /// of a movie that stands alone, or one without a title of its own), so its scenes read apart.
    pub fn shown_title(&self) -> String {
        let base = if self.title.is_empty() { self.series.clone() } else { self.title.clone() };
        let whole_work = self.title.is_empty() || self.series.is_empty() || self.title.eq_ignore_ascii_case(&self.series);
        match &self.part {
            Some(part) if whole_work => format!("{base} · {part}"),
            _ => base,
        }
    }

    /// The fields this record writes into Plex.
    pub fn render(&self) -> Desired {
        let title = self.shown_title();
        let number = self.part.as_deref().and_then(|part| part.rsplit(' ').next()).and_then(|number| number.parse::<u32>().ok());
        let work = if self.series.is_empty() { self.title.as_str() } else { self.series.as_str() };
        let title_sort = [work, self.date.as_str(), &number.map(|number| format!("{number:03}")).unwrap_or_default(), title.as_str()]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        let tagline = if !self.series.is_empty() && !title.starts_with(&self.series) { self.series.clone() } else { String::new() };
        Desired {
            title,
            title_sort,
            summary: self.summary.clone(),
            tagline,
            studio: self.studio.clone(),
            date: if parse_date(&self.date).is_some() { self.date.clone() } else { String::new() },
            year: self.year.unwrap_or(0),
            genres: self.genres.clone(),
            collections: if self.series.is_empty() { Vec::new() } else { vec![self.series.clone()] },
            cast: self.people.clone(),
            poster: self.poster_url.clone(),
            background: None,
        }
    }
}

/// Researches the file `work` names in a library of `kind`. `newest` is the last day (days since 1970) the work can have
/// come out, from when Plex added the file, and `added` the same day written out for the model.
#[allow(clippy::too_many_arguments)]
pub async fn research_work(
    brain: &Brain,
    web: &Web,
    kind: Kind,
    work: &Work,
    library: &str,
    added: &str,
    newest: i64,
    step: &(dyn Fn(Step) + Send + Sync),
) -> Result<(WorkRecord, Took), super::research::ResearchError> {
    let adult = kind == Kind::Adult || work.looks_adult();
    if adult {
        let name = format!("{} {}", work.file_name.replace(['.', '_'], " "), work.folder.as_deref().unwrap_or(""));
        if let Some(hint) = super::ages::name_hint(&name) {
            return Ok((WorkRecord::refused(&format!("its name says \"{hint}\"")), Took::default()));
        }
    }
    let system = if adult { ADULT } else { GENERAL };
    let (mut record, took) = investigate(brain, web, system, work.brief(library, added), &submit(), step, |call: &ToolCall, seen, sent_back| {
        let mut record: WorkRecord =
            serde_json::from_value(call.arguments.clone()).map_err(|error| vec![format!("The record does not match the schema: {error}.")])?;
        record.settle(work);
        if record.poster_url.as_ref().is_some_and(|url| !seen.images.contains(url)) {
            record.poster_url = None;
        }
        let problems = record.problems(&seen.known, newest);
        if problems.is_empty() {
            return Ok(record);
        }
        if sent_back {
            record.sources.retain(|source| super::research::seen_source(&seen.known, source));
            if record.problems(&seen.known, newest).is_empty() {
                record.confidence = "low".into();
                return Ok(record);
            }
        }
        Err(problems)
    })
    .await?;
    if record.identified && (adult || record.looks_adult()) {
        step(Step::Checking);
        let mentions = super::ages::mentions(&record, &took.texts);
        tracing::info!(file = %work.file_name, sentences = mentions.len(), "checking what the pages say of ages");
        if let Some(hint) = super::ages::judged(brain, &record, &mentions).await.map_err(super::research::ResearchError::Model)? {
            record = WorkRecord::refused(&hint);
        }
    }
    Ok((record, took))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_adult_release_names_give_away() {
        let scene = Work::read("/media/Holy Grail/!!Young Harlots In London - sc2 400p.mkv");
        assert_eq!((scene.cleaned.as_str(), scene.part.as_deref()), ("Young Harlots In London", Some("Scene 2")));
        assert_ne!(scene.key, Work::read("/media/Holy Grail/!!Young Harlots In London - sc1 400p.mkv").key);
        assert_eq!(scene.key, Work::read("/media/Holy Grail/!!Young Harlots In London - sc2 720p.mp4").key);
        let dated = Work::read("CumFiesta - 2007.03.13 Tempted To Touch.mp4");
        assert_eq!(dated.date.as_deref(), Some("2007-03-13"));
        assert_eq!(dated.cleaned, "CumFiesta - Tempted To Touch");
        let copies = [Work::read("!About Face 2 384p.avi"), Work::read("!About Face 2 384p.mp4")];
        assert_eq!(copies[0].key, copies[1].key);
        assert_eq!(copies[0].cleaned, "About Face 2");
        let short = Work::read("Brazzers.24.05.17.Jane.Doe.Office.Hours.XXX.1080p.HEVC.x265-GROUP.mkv");
        assert_eq!(short.date.as_deref(), Some("2024-05-17"));
        assert_eq!(short.cleaned, "Brazzers Jane Doe Office Hours");
        assert_eq!(Work::read("Vixen.99.12.31.Some.Title.XXX.480p.mp4").date.as_deref(), Some("1999-12-31"));
        assert_eq!(Work::read("Studio.Name.Movie.2007.part1.vob").cleaned, "Studio Name Movie 2007");
        assert_eq!(Work::read("A Proper Lady - sc1 720p.mp4").cleaned, "A Proper Lady");
        assert_eq!(Work::read("xXx - Trailer.mkv").cleaned, "xXx - Trailer");
        let dates = [Work::read("CumFiesta - 2007.03.13 Tempted To Touch.mp4"), Work::read("CumFiesta - 2010.01.01 Tempted To Touch.mkv")];
        assert_ne!(dates[0].key, dates[1].key);
        let year = Work::read("!BigTitsAtWork - 2010 1080p.part.mp4");
        assert_eq!((year.year, year.cleaned.as_str()), (Some(2010), "BigTitsAtWork - 2010"));
    }

    #[test]
    fn reads_game_cinematics_with_their_folder() {
        let work = Work::read("/media/Game Cinematics/StarCraft II/01 - Wings of Liberty - The Deal.mkv");
        assert_eq!(work.cleaned, "01 - Wings of Liberty - The Deal");
        assert_eq!(work.folder.as_deref(), Some("StarCraft II"));
        let brief = work.brief("Game Cinematics", "2026-11-01");
        assert!(brief.contains("Folder: StarCraft II") && brief.contains("Library: Game Cinematics"));
        let game = Work::read("/media/Game Cinematics/StarCraft II/SC2 - 01 - Wings of Liberty - The Deal.mkv");
        assert_eq!((game.part, game.cleaned.as_str()), (None, "SC2 - 01 - Wings of Liberty - The Deal"));
        assert_eq!(Work::read("Battlefield 2042 - Launch Trailer.mp4").year, None);
        assert_ne!(Work::read("/media/Games/Game A/trailer.mp4").key, Work::read("/media/Games/Game B/trailer.mkv").key);
    }

    #[test]
    fn marks_files_of_general_libraries_that_look_adult() {
        assert!(Work::read("/media/Other/XXX/Some Scene 720p.mp4").looks_adult());
        assert!(!Work::read("/media/Games/StarCraft II/The Deal.mkv").looks_adult());
    }

    fn record() -> WorkRecord {
        WorkRecord {
            identified: true,
            title: "Young Harlots In London".into(),
            series: "Young Harlots In London".into(),
            studio: "Harmony Films".into(),
            date: "2009-06-01".into(),
            people: vec!["Jane Doe".into(), " Jane  Doe ".into(), "Mary Major".into()],
            genres: vec!["Feature".into()],
            summary: "A feature from Harmony Films \u{2014} set in London.".into(),
            sources: vec!["https://www.iafd.com/title.rme/id=1".into()],
            confidence: "High".into(),
            ..WorkRecord::default()
        }
    }

    #[test]
    fn a_scene_of_a_movie_is_titled_with_its_scene_and_sorted_in_order() {
        let mut found = record();
        found.settle(&Work::read("!!Young Harlots In London - sc2 400p.mkv"));
        assert_eq!(found.people, vec!["Jane Doe", "Mary Major"]);
        assert_eq!(found.summary, "A feature from Harmony Films - set in London.");
        let desired = found.render();
        assert_eq!(desired.title, "Young Harlots In London · Scene 2");
        assert_eq!(desired.title_sort, "Young Harlots In London 2009-06-01 002 Young Harlots In London · Scene 2");
        assert_eq!((desired.year, desired.collections.len(), desired.cast.len()), (2009, 1, 2));
        let mut alone = record();
        alone.series.clear();
        alone.settle(&Work::read("!!Young Harlots In London - sc1 400p.mkv"));
        assert_eq!(alone.render().title, "Young Harlots In London · Scene 1");
        assert!(alone.render().title_sort.starts_with("Young Harlots In London 2009-06-01 001"));
    }

    #[test]
    fn checks_sources_and_dates_and_keeps_nothing_of_a_refused_work() {
        let mut found = record();
        found.settle(&Work::read("x.mp4"));
        let known: BTreeSet<String> = ["https://www.iafd.com/title.rme/id=1".to_string()].into();
        assert!(found.problems(&known, super::super::record::days_from_civil(2026, 1, 1)).is_empty());
        assert!(!found.problems(&BTreeSet::new(), i64::MAX).is_empty());
        assert!(!found.problems(&known, super::super::record::days_from_civil(2008, 1, 1)).is_empty());
        let refused = WorkRecord::refused("iafd.com says \"She was 16\"");
        assert!(!refused.identified && refused.people.is_empty() && refused.notes.starts_with(REFUSED));
    }
}
