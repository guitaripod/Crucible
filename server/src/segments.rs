//! The skippable stretches of one item: Plex's own markers first, then what the file's chapter names say.
//! The same rules as the app's `SkipSegments`, so a device without the server and one with it agree.

use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

/// What a stretch of an episode is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Intro,
    Recap,
    Preview,
    Ending,
    Credits,
    Commercial,
}

/// Where a segment's bounds came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Plex,
    Chapter,
    Fingerprint,
}

/// One skippable stretch, in milliseconds from the start of the file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    pub kind: Kind,
    pub start_ms: u64,
    pub end_ms: u64,
    pub source: Source,
}

/// A Plex marker as `/library/metadata/{id}?includeMarkers=1` returns it.
#[derive(Clone, Debug)]
pub struct Marker {
    pub kind: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// A chapter as `includeChapters=1` returns it.
#[derive(Clone, Debug)]
pub struct Chapter {
    pub title: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

static RULES: LazyLock<Vec<(Kind, Regex)>> = LazyLock::new(|| {
    [
        (Kind::Intro, r"^(op\d*|opening( (song|theme|music|credits))?|intro|title sequence|オープニング)$"),
        (Kind::Recap, r"^(recap|previously( on)?|last time( on)?|previous episode|あらすじ|前回)$"),
        (Kind::Preview, r"^(preview|next( time)?( on)?|next episode( preview)?|sneak peek|次回予告|次回)$"),
        (Kind::Ending, r"^(ed\d*|(final )?ending( (song|theme|music))?|closing|outro|goodbye!?|エンディング)$"),
        (Kind::Credits, r"^(credits?|end credits)$"),
    ]
    .into_iter()
    .map(|(kind, pattern)| (kind, Regex::new(&format!("(?i){pattern}")).expect("chapter rule compiles")))
    .collect()
});

/// The kind a chapter title names, matched against the whole trimmed title so "Opening Credits" is never an ending.
pub fn kind_for_title(title: &str) -> Option<Kind> {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return None;
    }
    RULES.iter().find(|(_, rule)| rule.is_match(trimmed)).map(|(kind, _)| *kind)
}

/// Whether a named chapter sits where its kind belongs: an intro or recap near the start, a preview, ending or credits
/// near the end, each no longer than that kind ever runs. A mislabelled chapter fails here.
pub fn fits(kind: Kind, start_ms: u64, end_ms: u64, duration_ms: u64) -> bool {
    if end_ms <= start_ms || end_ms > duration_ms + 1_000 {
        return false;
    }
    let (start, length, duration) = (start_ms as f64 / 1000.0, (end_ms - start_ms) as f64 / 1000.0, duration_ms as f64 / 1000.0);
    match kind {
        Kind::Intro => start <= 300.0 && (30.0..=180.0).contains(&length),
        Kind::Recap => start <= 300.0 && (5.0..=180.0).contains(&length),
        Kind::Preview => start >= duration - 300.0 && (5.0..=120.0).contains(&length),
        Kind::Ending => start >= duration * 0.8 && (30.0..=180.0).contains(&length),
        Kind::Credits => start >= duration * 0.85 && length <= 300.0,
        Kind::Commercial => false,
    }
}

/// The segments the chapter names alone describe. `duration_ms` may be zero when unknown; the chapters' own end
/// then stands in for it.
pub fn from_chapters(chapters: &[Chapter], duration_ms: u64) -> Vec<Segment> {
    let mut ordered: Vec<&Chapter> = chapters.iter().collect();
    ordered.sort_by_key(|chapter| chapter.start_ms);
    let end = if duration_ms > 0 { duration_ms } else { ordered.last().map_or(0, |chapter| chapter.end_ms) };
    if end == 0 {
        return Vec::new();
    }
    ordered
        .into_iter()
        .filter_map(|chapter| {
            let kind = kind_for_title(&chapter.title)?;
            fits(kind, chapter.start_ms, chapter.end_ms, end).then_some(Segment {
                kind,
                start_ms: chapter.start_ms,
                end_ms: chapter.end_ms,
                source: Source::Chapter,
            })
        })
        .collect()
}

/// Every segment of the item, sorted by start: Plex's intro and credits markers, then the chapters that add what
/// the markers lack.
pub fn make(markers: &[Marker], chapters: &[Chapter], duration_ms: u64) -> Vec<Segment> {
    let server: Vec<Segment> = markers
        .iter()
        .map(|marker| Segment {
            kind: match marker.kind.as_str() {
                "credits" => Kind::Credits,
                "commercial" => Kind::Commercial,
                _ => Kind::Intro,
            },
            start_ms: marker.start_ms,
            end_ms: marker.end_ms,
            source: Source::Plex,
        })
        .collect();
    let added: Vec<Segment> = from_chapters(chapters, duration_ms)
        .into_iter()
        .filter(|segment| match segment.kind {
            Kind::Intro | Kind::Credits => !server.iter().any(|known| known.kind == segment.kind),
            Kind::Ending => !server.iter().any(|known| known.kind == Kind::Credits && overlaps(known, segment)),
            Kind::Recap | Kind::Preview | Kind::Commercial => true,
        })
        .collect();
    let mut all: Vec<Segment> = server.into_iter().chain(added).collect();
    all.sort_by_key(|segment| segment.start_ms);
    all
}

fn overlaps(a: &Segment, b: &Segment) -> bool {
    a.start_ms < b.end_ms && b.start_ms < a.end_ms
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chapter(title: &str, start: u64, end: u64) -> Chapter {
        Chapter { title: title.into(), start_ms: start * 1000, end_ms: end * 1000 }
    }

    fn anime_episode() -> Vec<Chapter> {
        vec![
            chapter("Opening Theme", 0, 90),
            chapter("Recap", 90, 140),
            chapter("Part A", 140, 700),
            chapter("Part B", 700, 1290),
            chapter("Ending Theme", 1290, 1380),
            chapter("Next Episode Preview", 1380, 1410),
        ]
    }

    #[test]
    fn an_anime_episodes_named_chapters_become_four_segments() {
        let kinds: Vec<Kind> = from_chapters(&anime_episode(), 1_410_000).iter().map(|s| s.kind).collect();
        assert_eq!(kinds, vec![Kind::Intro, Kind::Recap, Kind::Ending, Kind::Preview]);
    }

    #[test]
    fn whole_titles_only() {
        assert_eq!(kind_for_title("Opening Credits"), Some(Kind::Intro));
        assert_eq!(kind_for_title("  ED2 "), Some(Kind::Ending));
        assert_eq!(kind_for_title("次回予告"), Some(Kind::Preview));
        assert_eq!(kind_for_title("The Recap Club"), None);
        assert_eq!(kind_for_title(""), None);
    }

    #[test]
    fn a_chapter_out_of_place_is_ignored() {
        let chapters = vec![chapter("Recap", 900, 950), chapter("Preview", 10, 40)];
        assert!(from_chapters(&chapters, 1_400_000).is_empty());
    }

    #[test]
    fn plex_markers_win_over_chapters_of_their_kind() {
        let markers = vec![Marker { kind: "intro".into(), start_ms: 5_000, end_ms: 85_000 }];
        let segments = make(&markers, &anime_episode(), 1_410_000);
        let intros: Vec<&Segment> = segments.iter().filter(|s| s.kind == Kind::Intro).collect();
        assert_eq!(intros.len(), 1);
        assert_eq!(intros[0].source, Source::Plex);
        assert!(segments.iter().any(|s| s.kind == Kind::Recap && s.source == Source::Chapter));
    }

    #[test]
    fn an_ending_inside_plex_credits_is_dropped() {
        let markers = vec![Marker { kind: "credits".into(), start_ms: 1_285_000, end_ms: 1_410_000 }];
        let segments = make(&markers, &anime_episode(), 1_410_000);
        assert!(!segments.iter().any(|s| s.kind == Kind::Ending));
        assert!(segments.iter().any(|s| s.kind == Kind::Preview));
    }
}
