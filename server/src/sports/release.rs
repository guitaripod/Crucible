//! What a file's name says before anything is looked up: the name without the release's technical words, and for
//! leagues whose release names follow a pattern, the event and the part of the broadcast the file holds.

use std::sync::LazyLock;

use regex::Regex;

/// A file as its name describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub file_name: String,
    /// The name up to the first technical word, with dots and underscores as spaces: "UFC Fight Night 286 Nurmagomedov vs Song".
    pub cleaned: String,
    /// The event the name numbers, written the way the league numbers it: "UFC 334", "UFC Fight Night 286".
    pub event: Option<String>,
    /// The part of the broadcast, when the league splits it and the name says (or, by the league's convention, implies).
    pub part: Option<String>,
    /// What the name could mislead about, said to the model before it searches.
    pub caution: Option<&'static str>,
}

static EXTENSION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\.(mkv|mp4|m4v|avi|ts|m2ts|mov|wmv|webm)$").expect("extension pattern"));
static TECHNICAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(480|540|576|720|1080|1440|2160)[pi]\b|\b(4k|uhd|web[\s-]?dl|web[\s-]?rip|webrip|web|hdtv|pdtv|bluray|blu-ray|bdrip|dvdrip|x26[45]|h[\s.]?26[45]|hevc|avc|aac|ac3|eac3|dd[p+]?\d|satfeed|repack|proper)\b")
        .expect("technical pattern")
});
static UFC_EVENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bUFC\s+(?:(Fight\s+Night|PPV|Vegas|on\s+(?:ESPN\+?|ABC|FOX|FX|Fuel(?:\s+TV)?))\s*)?(\d{1,4})\b").expect("UFC pattern"));
static EARLY_PRELIMS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bearly\s+prelim(?:s|inary|inaries)?\b|\bUFP\b").expect("early prelims pattern"));
static PRELIMS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bprelim(?:s|inary|inaries)?\b").expect("prelims pattern"));
static FULL_EVENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\b(complete|full\s+event)\b").expect("full event pattern"));
static FIGHT_PASS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)\bUFC\s+Fight\s+Pass\b").expect("Fight Pass pattern"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("spaces pattern"));

pub const MAIN_CARD: &str = "Main card";
pub const PRELIMS_PART: &str = "Prelims";
pub const EARLY_PRELIMS_PART: &str = "Early prelims";
pub const FULL_EVENT_PART: &str = "Full event";

/// How a UFC event series is written: "UFC Fight Night", "UFC Vegas", "UFC on ESPN", or plain "UFC" for numbered
/// events, pay-per-view or not.
fn series_name(series: Option<&str>) -> String {
    let Some(series) = series else { return "UFC".into() };
    let words = SPACES.replace_all(series.trim(), " ").to_lowercase();
    match words.as_str() {
        "fight night" => "UFC Fight Night".into(),
        "vegas" => "UFC Vegas".into(),
        "ppv" => "UFC".into(),
        "on fuel" | "on fuel tv" => "UFC on Fuel TV".into(),
        network => format!("UFC on {}", network.trim_start_matches("on ").to_uppercase()),
    }
}

impl Release {
    /// Reads a file name, or a path whose last component is the file.
    pub fn read(path: &str) -> Self {
        let file_name = path.rsplit(['/', '\\']).next().unwrap_or(path).to_string();
        let stem = EXTENSION.replace(&file_name, "");
        let spaced = stem.replace(['.', '_'], " ");
        let head = TECHNICAL.find(&spaced).map_or(spaced.as_str(), |technical| &spaced[..technical.start()]);
        let cleaned = SPACES.replace_all(head.trim_matches([' ', '-']), " ").trim().to_string();
        let cleaned = if cleaned.is_empty() { SPACES.replace_all(spaced.trim(), " ").to_string() } else { cleaned };
        let event = UFC_EVENT.captures(&spaced).map(|found| format!("{} {}", series_name(found.get(1).map(|series| series.as_str())), &found[2]));
        let part = event.as_ref().map(|_| {
            if FULL_EVENT.is_match(&spaced) {
                FULL_EVENT_PART
            } else if EARLY_PRELIMS.is_match(&spaced) {
                EARLY_PRELIMS_PART
            } else if PRELIMS.is_match(&spaced) {
                PRELIMS_PART
            } else {
                MAIN_CARD
            }
            .to_string()
        });
        let caution = match (&event, FIGHT_PASS.is_match(&spaced)) {
            (None, true) => Some("\"UFC Fight Pass\" names the streaming service the event was shown on, not the promotion; the promotion is named before it."),
            (Some(event), _) if event.starts_with("UFC Vegas") => {
                Some("\"UFC Vegas\" with a number is the informal name of a UFC Fight Night held at the UFC Apex in Las Vegas; its official name is \"UFC Fight Night: A vs. B\".")
            }
            (Some(_), _) if EARLY_PRELIMS.is_match(&spaced) && !spaced.to_lowercase().contains("early") => {
                Some("\"UFP\" in a UFC release name is the UFC Fight Pass feed of the early prelims.")
            }
            _ => None,
        };
        Release { file_name, cleaned, event, part, caution }
    }

    /// Whether two files are parts of the same event as their names number it.
    pub fn same_event(&self, other: &Release) -> bool {
        self.event.is_some() && self.event == other.event
    }
}

/// The order parts are watched in: early prelims, prelims, the main card, then anything else.
pub fn part_order(part: Option<&str>) -> u8 {
    match part {
        Some(EARLY_PRELIMS_PART) => 1,
        Some(PRELIMS_PART) => 2,
        Some(MAIN_CARD) | None => 3,
        Some(FULL_EVENT_PART) => 0,
        Some(_) => 4,
    }
}

/// A part as a model or a page writes it, in the words the library uses.
pub fn canonical_part(part: &str) -> Option<String> {
    let folded = SPACES.replace_all(part.trim().to_lowercase().as_str(), " ").to_string();
    if folded.is_empty() || folded == "null" || folded == "none" {
        return None;
    }
    let canonical = match folded.as_str() {
        "main card" | "main" | "main event" | "ppv" | "pay-per-view" | "main card ppv" => MAIN_CARD,
        "prelims" | "prelim" | "preliminary card" | "preliminaries" | "preliminary" | "prelim card" => PRELIMS_PART,
        "early prelims" | "early prelim" | "early preliminary card" | "early preliminaries" | "early preliminary" => EARLY_PRELIMS_PART,
        "full event" | "full card" | "complete" | "complete event" | "whole event" => FULL_EVENT_PART,
        _ => {
            let mut letters = folded.chars();
            return letters.next().map(|first| first.to_uppercase().chain(letters).collect());
        }
    };
    Some(canonical.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(name: &str) -> (String, Option<String>, Option<String>) {
        let release = Release::read(name);
        (release.cleaned, release.event, release.part)
    }

    #[test]
    fn reads_ufc_release_names() {
        assert_eq!(read("UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4"), ("UFC 334 Prelims".into(), Some("UFC 334".into()), Some("Prelims".into())));
        assert_eq!(
            read("/mnt/stuff2/Sports/x/ufc.fight.night.286.nurmagomedov.vs.song.1080p.web.h264-verum.mkv"),
            ("ufc fight night 286 nurmagomedov vs song".into(), Some("UFC Fight Night 286".into()), Some("Main card".into()))
        );
        assert_eq!(read("UFC.332.Silva.vs.Wang.Early.Prelims.1080p.WEB.h264-VERUM.mkv").2, Some("Early prelims".into()));
        assert_eq!(read("UFC.Fight.Night.280.Preliminary.Fiziev.vs.Torres.1080p.WEBRip.H264-Star.mp4").2, Some("Prelims".into()));
        assert_eq!(read("UFC.Fight.Night.283.UFP.1080p.WEBRip.H264-Star.mp4").2, Some("Early prelims".into()));
        assert!(Release::read("UFC.Fight.Night.283.UFP.1080p.WEBRip.H264-Star.mp4").caution.unwrap().contains("UFP"));
        assert_eq!(read("UFC.330.PPV.Makhachev.vs.Machado.Garry.Satfeed.1080p.HDTV.H264-Star.mp4").1, Some("UFC 330".into()));
        assert_eq!(read("UFC PPV 332 Silva vs Wang 1080p").1, Some("UFC 332".into()));
        assert_eq!(read("UFC.229.720p.HDTV.x264-VERUM.mkv"), ("UFC 229".into(), Some("UFC 229".into()), Some("Main card".into())));
        assert_eq!(read("UFC 332 Silva vs Wang COMPLETE 1080i FEED x264-GITA.mkv").2, Some("Full event".into()));
        assert_eq!(read("UFC.Vegas.98.Prelims.1080p.WEB.h264-VERUM.mkv"), ("UFC Vegas 98 Prelims".into(), Some("UFC Vegas 98".into()), Some("Prelims".into())));
        assert!(Release::read("UFC.Vegas.98.Prelims.1080p.WEB.h264-VERUM.mkv").caution.unwrap().contains("UFC Apex"));
        assert_eq!(read("UFC.on.ESPN.60.Prelims.1080p.WEB.h264-VERUM.mkv").1, Some("UFC on ESPN 60".into()));
        assert_eq!(read("UFC on ABC 9 Main Card 1080p").1, Some("UFC on ABC 9".into()));
        assert_eq!(read("UFC.on.Fuel.TV.10.720p.HDTV.x264.mkv").1, Some("UFC on Fuel TV 10".into()));
        assert_eq!(read("UFC on ESPN+ 45 1080p").1, Some("UFC on ESPN+ 45".into()));
    }

    #[test]
    fn leaves_other_promotions_and_sports_to_the_model() {
        let samourai = Release::read("Samourai.MMA.21.UFC.Fight.Pass.1080p.WEBRip.H264-Star.mp4");
        assert_eq!((samourai.cleaned.as_str(), samourai.event, samourai.part), ("Samourai MMA 21 UFC Fight Pass", None, None));
        assert!(samourai.caution.unwrap().contains("streaming service"));
        let race = Release::read("Formula1.2026.Round05.Miami.Grand.Prix.Race.1080p.F1TV.WEB-DL.AAC2.0.H.264-NTb.mkv");
        assert_eq!((race.cleaned.as_str(), race.event, race.part), ("Formula1 2026 Round05 Miami Grand Prix Race", None, None));
        assert_eq!(Release::read("UFC BJJ 13 Tackett vs Rodriguez 2026 1080p WEB-DL H264 Fight-BB.mp4").event, None);
    }

    #[test]
    fn parts_read_the_way_the_library_writes_them() {
        assert_eq!(canonical_part("Preliminary Card").as_deref(), Some("Prelims"));
        assert_eq!(canonical_part("EARLY PRELIMS").as_deref(), Some("Early prelims"));
        assert_eq!(canonical_part("main card").as_deref(), Some("Main card"));
        assert_eq!(canonical_part("qualifying").as_deref(), Some("Qualifying"));
        assert_eq!(canonical_part(" null "), None);
        assert!(part_order(Some("Early prelims")) < part_order(Some("Prelims")) && part_order(Some("Prelims")) < part_order(Some("Main card")));
    }
}
