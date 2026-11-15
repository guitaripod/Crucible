//! What the research model hands in, the checks it must pass, and how a checked record becomes the fields Plex shows.
//! Everything after the model is plain code, so the same record always gives the same title, summary and sort order.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};

use super::release::{canonical_part, part_order, Release, FULL_EVENT_PART, MAIN_CARD};

/// One bout or fixture on the card, as it stood before the event.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Bout {
    pub matchup: String,
    pub detail: String,
    pub part: Option<String>,
}

/// The research model's record of one event, plus the part of it one file holds.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Record {
    pub identified: bool,
    pub sport: String,
    pub league: String,
    pub event: String,
    pub event_number: Option<String>,
    pub part: Option<String>,
    pub date: String,
    pub venue: String,
    pub city: String,
    pub headline: String,
    pub lineup: Vec<Bout>,
    pub summary: String,
    pub poster_url: Option<String>,
    pub background_url: Option<String>,
    pub sources: Vec<String>,
    pub confidence: String,
    pub notes: String,
    /// The event number the model gave before the file name's replaced it, kept only to check the two agree.
    #[serde(skip)]
    pub claimed_number: Option<String>,
}

/// The fields written to Plex for one item.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Desired {
    pub title: String,
    pub title_sort: String,
    pub summary: String,
    pub tagline: String,
    pub studio: String,
    pub date: String,
    pub year: i32,
    pub genres: Vec<String>,
    pub collections: Vec<String>,
    pub poster: Option<String>,
    pub background: Option<String>,
}

static VS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\s+(?:vs\.?|v\.?)\s+").expect("vs pattern"));
static SPOILER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(\bdef\.|\bdefeat(?:ed|s)\b|\bknocked out\b|\bknockout win\b|\bsubmitted\b|\bsubmission win\b|\bby (?:unanimous|split|majority) decision\b|\bretain(?:ed|s) (?:the|his|her) (?:title|belt)\b|\bsuccessfully defended\b|\bnew champion\b|\bupset win\b|\bfinal score\b|\bvictory over\b|\bwon the (?:fight|bout|race|game|match)\b)",
    )
    .expect("spoiler pattern")
});
static ROUND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\s*(round|week|matchday|game|race|stage|leg)\b").expect("round pattern"));
static DATE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d{4})-(\d{2})-(\d{2})$").expect("date pattern"));

/// Words in the record that give away how the event went.
pub fn spoilers(text: &str) -> Vec<String> {
    SPOILER.find_iter(text).map(|found| found.as_str().to_string()).collect::<BTreeSet<_>>().into_iter().collect()
}

/// `text` without the sentences that give a result away.
pub fn without_spoilers(text: &str) -> String {
    static SENTENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^.!?]+(?:[.!?]+|$)").expect("sentence pattern"));
    SENTENCE.find_iter(text).map(|sentence| sentence.as_str()).filter(|sentence| spoilers(sentence).is_empty()).collect::<String>().trim().to_string()
}

/// "Gane vs Hokit" and "Gane v. Hokit" as "Gane vs. Hokit".
pub fn tidy_matchup(text: &str) -> String {
    VS.replace_all(text.trim(), " vs. ").replace(['—', '–'], "-")
}

/// A date the record gives, as (year, month, day), when it is a real calendar date.
pub fn parse_date(text: &str) -> Option<(i32, u32, u32)> {
    let found = DATE.captures(text.trim())?;
    let (year, month, day) = (found[1].parse().ok()?, found[2].parse().ok()?, found[3].parse().ok()?);
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => return None,
    };
    (1900..=2200).contains(&year).then_some(()).filter(|_| (1..=days).contains(&day)).map(|_| (year, month, day))
}

/// Days since 1970-01-01 for a calendar date.
pub fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year } as i64;
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let of_era = year - era * 400;
    let shifted_month = (month as i64 + 9) % 12;
    let of_year = (153 * shifted_month + 2) / 5 + day as i64 - 1;
    let of_cycle = of_era * 365 + of_era / 4 - of_era / 100 + of_year;
    era * 146_097 + of_cycle - 719_468
}

const WEEKDAYS: [&str; 7] = ["Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday"];
const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/// "Saturday 14 November 2026".
pub fn long_date(year: i32, month: u32, day: u32) -> String {
    let weekday = WEEKDAYS[days_from_civil(year, month, day).rem_euclid(7) as usize];
    format!("{weekday} {day} {} {year}", MONTHS[(month - 1) as usize])
}

fn domain(url: &str) -> Option<String> {
    let host = reqwest::Url::parse(url).ok()?.host_str()?.to_lowercase();
    Some(host.strip_prefix("www.").unwrap_or(&host).to_string())
}

impl Record {
    /// Brings the record to the library's own words: the part and event number the file name gives win over the
    /// model's, matchups read "A vs. B", and parts are named one way.
    pub fn settle(&mut self, release: &Release) {
        if self.claimed_number.is_none() {
            self.claimed_number = self.event_number.clone();
        }
        if let Some(number) = &release.event {
            self.event_number = Some(number.clone());
            if number.starts_with("UFC") {
                self.league = "UFC".into();
                if self.sport.trim().is_empty() {
                    self.sport = "Mixed Martial Arts".into();
                }
            }
        }
        if release.event.is_none() && self.event_number.as_deref().is_some_and(|number| ROUND.is_match(number)) {
            self.event_number = None;
        }
        self.part = release.part.clone().or_else(|| self.part.as_deref().and_then(canonical_part));
        self.headline = tidy_matchup(&self.headline);
        self.event = tidy_matchup(&self.event);
        for bout in &mut self.lineup {
            bout.matchup = tidy_matchup(&bout.matchup);
            bout.detail = bout.detail.trim().trim_end_matches(" Bout").trim_end_matches(" bout").trim().to_string();
            bout.part = bout.part.as_deref().and_then(canonical_part);
        }
        self.lineup.retain(|bout| !bout.matchup.is_empty());
        self.summary = self.summary.trim().replace(['—', '–'], "-");
        self.confidence = match self.confidence.to_lowercase().as_str() {
            "high" => "high",
            "medium" => "medium",
            _ => "low",
        }
        .into();
        let mut seen = BTreeSet::new();
        self.sources.retain(|source| seen.insert(source.trim().to_string()));
    }

    /// What is wrong with the record, in sentences the model can act on. `known` holds every address the research
    /// saw in results or read, and `newest` is the latest day (days since 1970) the event can have taken place.
    pub fn problems(&self, release: &Release, known: &BTreeSet<String>, newest: i64) -> Vec<String> {
        let mut problems = Vec::new();
        if !self.identified {
            return problems;
        }
        if self.event.trim().is_empty() {
            problems.push("event is empty: give the event's canonical name.".into());
        }
        match parse_date(&self.date) {
            None => problems.push(format!("date \"{}\" is not a calendar date in YYYY-MM-DD.", self.date)),
            Some((year, month, day)) if days_from_civil(year, month, day) > newest => {
                problems.push(format!("date {} is after the file was added to the library, so it cannot be this event.", self.date))
            }
            _ => {}
        }
        if self.sources.is_empty() {
            problems.push("sources is empty: list the pages that confirm the event and its date.".into());
        }
        let unseen: Vec<&String> = self.sources.iter().filter(|source| !known.contains(source.trim())).collect();
        if !unseen.is_empty() && unseen.len() == self.sources.len() {
            problems.push("none of the sources is a page you saw in search results or read: cite those pages.".into());
        }
        if let Some(number) = &release.event {
            let wanted = number.to_lowercase();
            let names_it = |text: &str| {
                let text = text.to_lowercase().replace("ppv ", "");
                text.match_indices(&wanted).any(|(at, _)| !text[at + wanted.len()..].starts_with(|c: char| c.is_ascii_digit()))
            };
            let claimed = self.claimed_number.as_deref().unwrap_or("");
            if !names_it(claimed) && !names_it(&self.event) {
                let said = if claimed.is_empty() { self.event.as_str() } else { claimed };
                problems.push(format!("the file name numbers the event {number}, but the record says {said}: identify {number}."));
            }
        }
        let leaks = [self.summary.as_str(), self.headline.as_str(), self.event.as_str()]
            .into_iter()
            .chain(self.lineup.iter().flat_map(|bout| [bout.matchup.as_str(), bout.detail.as_str()]))
            .flat_map(spoilers)
            .collect::<BTreeSet<_>>();
        if !leaks.is_empty() {
            problems.push(format!(
                "the record gives results away ({}): describe the matchups as they stood before the event, with no winners or outcomes.",
                leaks.into_iter().collect::<Vec<_>>().join(", ")
            ));
        }
        problems
    }

    /// The event's own title: "UFC 334: Gane vs. Hokit" when the league numbers its events, else the event's name.
    pub fn event_title(&self) -> String {
        let headline = self.headline.trim();
        let event = self.event.trim();
        match &self.event_number {
            Some(number) if !headline.is_empty() => format!("{number}: {headline}"),
            Some(number) if event.is_empty() => number.clone(),
            _ if !event.is_empty() => event.to_string(),
            _ => headline.to_string(),
        }
    }

    /// The bouts this file shows: the ones on its part of the card, or the whole card when the parts are not told apart.
    pub fn bouts_for(&self, part: Option<&str>) -> Vec<&Bout> {
        let labelled = self.lineup.iter().any(|bout| bout.part.is_some());
        match part {
            Some(part) if labelled && part != FULL_EVENT_PART => self.lineup.iter().filter(|bout| bout.part.as_deref() == Some(part)).collect(),
            _ => self.lineup.iter().collect(),
        }
    }

    /// The fields Plex shows for the file this record describes. `in_collection` is whether more than one part of the
    /// event is in the library, so the parts are grouped; a lone file is never hidden behind a collection of one.
    pub fn render(&self, in_collection: bool) -> Desired {
        let event_title = self.event_title();
        let part = self.part.as_deref();
        let title = match part {
            None | Some(MAIN_CARD) | Some(FULL_EVENT_PART) => event_title.clone(),
            Some(part) => format!("{event_title} · {part}"),
        };
        let date = parse_date(&self.date);
        let league = if self.league.trim().is_empty() { self.sport.trim() } else { self.league.trim() };
        let title_sort = format!("{} {} {} {}", league, self.date.trim(), part_order(part), event_title).trim().to_string();
        let mut summary = self.summary.trim().to_string();
        let bouts: Vec<&Bout> = self.bouts_for(part).into_iter().filter(|bout| bout.matchup.contains(" vs. ")).collect();
        if !bouts.is_empty() {
            let heading = match part {
                Some(FULL_EVENT_PART) | None => "The card",
                Some(part) => part,
            };
            let lines: Vec<String> =
                bouts.iter().map(|bout| if bout.detail.is_empty() { bout.matchup.clone() } else { format!("{} · {}", bout.detail, bout.matchup) }).collect();
            summary = format!("{summary}\n\n{heading}\n{}", lines.join("\n")).trim().to_string();
        }
        let place = if !self.city.trim().is_empty() && self.venue.contains(self.city.trim()) {
            self.venue.trim().to_string()
        } else {
            [self.venue.trim(), self.city.trim()].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(", ")
        };
        let when = date.map(|(year, month, day)| long_date(year, month, day));
        let footer = [when.as_deref().unwrap_or(""), place.as_str()].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join(" · ");
        if !footer.is_empty() {
            summary = format!("{summary}\n\n{footer}").trim().to_string();
        }
        let domains: Vec<String> = self.sources.iter().filter_map(|source| domain(source)).collect::<BTreeSet<_>>().into_iter().take(4).collect();
        if !domains.is_empty() {
            summary = format!("{summary}\nResearched by Crucible Server from {}.", domains.join(", "));
        }
        Desired {
            title,
            title_sort,
            summary,
            tagline: self.headline.trim().to_string(),
            studio: league.to_string(),
            date: date.map(|_| self.date.trim().to_string()).unwrap_or_default(),
            year: date.map_or(0, |(year, _, _)| year),
            genres: if self.sport.trim().is_empty() { Vec::new() } else { vec![self.sport.trim().to_string()] },
            collections: if in_collection { vec![event_title] } else { Vec::new() },
            poster: self.poster_url.clone().filter(|url| url.starts_with("http")),
            background: self.background_url.clone().filter(|url| url.starts_with("http")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ufc334() -> Record {
        Record {
            identified: true,
            sport: "Mixed Martial Arts".into(),
            league: "UFC".into(),
            event: "UFC 334: Gane vs Hokit".into(),
            event_number: Some("UFC 334".into()),
            part: Some("prelims".into()),
            date: "2026-11-14".into(),
            venue: "Madison Square Garden".into(),
            city: "New York City, New York, United States".into(),
            headline: "Gane vs Hokit".into(),
            lineup: vec![
                Bout { matchup: "Ciryl Gane vs Josh Hokit".into(), detail: "Heavyweight".into(), part: Some("Main Card".into()) },
                Bout { matchup: "Stephen Thompson v. Charles Radtke".into(), detail: "Welterweight".into(), part: Some("Preliminary card".into()) },
            ],
            summary: "Two contenders meet at the Garden.".into(),
            poster_url: Some("https://ufc.com/images/ufc-334-EVENT-ART.jpg".into()),
            background_url: None,
            sources: vec!["https://en.wikipedia.org/wiki/UFC_334".into(), "https://www.ufc.com/event/ufc-334".into()],
            confidence: "High".into(),
            notes: String::new(),
            claimed_number: None,
        }
    }

    #[test]
    fn renders_a_part_of_a_numbered_event() {
        let mut record = ufc334();
        record.settle(&Release::read("UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"));
        let desired = record.render(true);
        assert_eq!(desired.title, "UFC 334: Gane vs. Hokit · Prelims");
        assert_eq!(desired.title_sort, "UFC 2026-11-14 2 UFC 334: Gane vs. Hokit");
        assert_eq!(desired.collections, vec!["UFC 334: Gane vs. Hokit"]);
        assert_eq!((desired.date.as_str(), desired.year, desired.studio.as_str()), ("2026-11-14", 2026, "UFC"));
        assert_eq!(
            desired.summary,
            "Two contenders meet at the Garden.\n\nPrelims\nWelterweight · Stephen Thompson vs. Charles Radtke\n\nSaturday 14 November 2026 · Madison Square Garden, New York City, New York, United States\nResearched by Crucible Server from en.wikipedia.org, ufc.com."
        );
        assert_eq!(desired.tagline, "Gane vs. Hokit");
        assert_eq!(desired.genres, vec!["Mixed Martial Arts"]);
    }

    #[test]
    fn the_main_card_carries_the_event_title_alone_and_a_lone_file_no_collection() {
        let mut record = ufc334();
        record.settle(&Release::read("UFC.334.Main.Card.1080p.WEB-DL.H264-nVa.mkv"));
        let desired = record.render(false);
        assert_eq!(desired.title, "UFC 334: Gane vs. Hokit");
        assert!(desired.collections.is_empty());
        assert!(desired.summary.contains("Main card\nHeavyweight · Ciryl Gane vs. Josh Hokit"));
    }

    #[test]
    fn checks_dates_sources_numbers_and_spoilers() {
        let release = Release::read("UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4");
        let known: BTreeSet<String> = ["https://en.wikipedia.org/wiki/UFC_334".to_string()].into();
        let added = days_from_civil(2026, 11, 15);
        let mut record = ufc334();
        record.settle(&release);
        assert!(record.problems(&release, &known, added).is_empty());

        let mut late = record.clone();
        late.date = "2026-11-21".into();
        assert!(late.problems(&release, &known, added)[0].contains("after the file was added"));
        let mut invented = record.clone();
        invented.sources = vec!["https://made.up/page".into()];
        assert!(invented.problems(&release, &known, added)[0].contains("none of the sources"));
        let mut wrong = ufc334();
        wrong.event = "UFC 333: Someone vs. Else".into();
        wrong.event_number = Some("UFC 333".into());
        wrong.settle(&release);
        assert_eq!(wrong.event_number.as_deref(), Some("UFC 334"));
        assert!(wrong.problems(&release, &known, added)[0].contains("numbers the event UFC 334, but the record says UFC 333"));
        let mut longer = ufc334();
        longer.event = "UFC 3345".into();
        longer.event_number = Some("UFC 3345".into());
        longer.settle(&release);
        assert!(!longer.problems(&release, &known, added).is_empty());
        let mut named = ufc334();
        named.event_number = None;
        named.settle(&release);
        assert!(named.problems(&release, &known, added).is_empty());
        let mut spoiled = record.clone();
        spoiled.summary = "Gane defeated Hokit by unanimous decision.".into();
        let problems = spoiled.problems(&release, &known, added);
        assert!(problems[0].contains("defeated") && problems[0].contains("by unanimous decision"));
        let mut preview = record.clone();
        preview.summary = "Gane, who won the interim title in 2024, has beaten three ranked heavyweights.".into();
        assert!(preview.problems(&release, &known, added).is_empty());
        let mut titled = record.clone();
        titled.event = "UFC 334: Gane defeats Hokit".into();
        assert!(!titled.problems(&release, &known, added).is_empty());
        assert_eq!(without_spoilers("Two heavyweights meet. Gane defeated Hokit. The Garden is sold out."), "Two heavyweights meet. The Garden is sold out.");
        assert!(Record { identified: false, ..Record::default() }.problems(&release, &known, added).is_empty());
        let mut bad_date = record;
        bad_date.date = "2026-02-30".into();
        assert!(bad_date.problems(&release, &known, added)[0].contains("not a calendar date"));
    }

    #[test]
    fn titles_events_the_league_does_not_number() {
        let record = Record {
            identified: true,
            sport: "Formula 1".into(),
            league: "Formula 1".into(),
            event: "2026 Miami Grand Prix".into(),
            part: Some("Race".into()),
            date: "2026-05-03".into(),
            ..Record::default()
        };
        let desired = record.render(false);
        assert_eq!(desired.title, "2026 Miami Grand Prix · Race");
        assert_eq!(desired.summary, "Sunday 3 May 2026");
    }

    #[test]
    fn a_round_of_a_season_is_not_an_event_number() {
        let mut record = Record {
            identified: true,
            event: "2026 Miami Grand Prix".into(),
            event_number: Some("Round 5".into()),
            headline: String::new(),
            part: Some("Race".into()),
            date: "2026-05-03".into(),
            ..Record::default()
        };
        record.lineup = vec![
            Bout { matchup: "Kimi Antonelli".into(), detail: "Mercedes".into(), part: None },
            Bout { matchup: "Max Verstappen".into(), detail: "Red Bull Racing".into(), part: None },
        ];
        record.settle(&Release::read("Formula1.2026.Round05.Miami.Grand.Prix.Race.1080p.F1TV.WEB-DL.AAC2.0.H.264-NTb.mkv"));
        assert_eq!(record.event_number, None);
        let desired = record.render(false);
        assert_eq!(desired.title, "2026 Miami Grand Prix · Race");
        assert!(!desired.summary.contains("Antonelli"), "an entry list is never shown, since its order can give a result away");
    }

    #[test]
    fn calendar_arithmetic() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2026, 11, 14), 20_771);
        assert_eq!(long_date(2026, 11, 14), "Saturday 14 November 2026");
        assert_eq!(long_date(2018, 10, 6), "Saturday 6 October 2018");
        assert_eq!(parse_date("2024-02-29"), Some((2024, 2, 29)));
        assert_eq!(parse_date("2026-13-01"), None);
    }
}
