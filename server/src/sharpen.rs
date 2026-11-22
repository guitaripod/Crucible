//! Moves Plex's intro marker onto the picture's own edges, the same rules as the app's `MarkerSnap`. Plex finds an intro
//! by its theme music, which often begins over the cold open's last shot and stops before the title card fades out, so its
//! marker starts and ends a few seconds early. ffmpeg reads a few seconds around each end, small and silent, and the
//! marker moves to the first cut or black after a cold open's end and to the black (else a cut) just after the titles,
//! never further than a few seconds. Without ffmpeg, or with no clear edge, the marker stays as Plex made it.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use regex::Regex;
use tokio::process::Command;

use crate::segments::{Kind, Segment, Source};

/// A picture's edges near a marker, in seconds on the item's timeline.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Edges {
    pub cuts: Vec<f64>,
    pub black_ends: Vec<f64>,
}

const START_BEFORE: f64 = 1.0;
const START_AFTER: f64 = 4.5;
const END_BEFORE: f64 = 1.5;
const END_AFTER: f64 = 4.0;
/// An intro that opens the episode has no cold open to wait out, only cuts inside its own titles.
const COLD_OPEN_MINIMUM: f64 = 10.0;

static KNOWN: LazyLock<Mutex<HashMap<String, (u64, u64)>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static CUT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"lavfi\.scd\.time: ([0-9.]+)").expect("cut pattern compiles"));
static BLACK_END: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"black_end:([0-9.]+)").expect("black pattern compiles"));

pub fn refined_start(start: f64, edges: &Edges) -> f64 {
    if start <= COLD_OPEN_MINIMUM {
        return start;
    }
    let mut all: Vec<f64> = edges.cuts.iter().chain(&edges.black_ends).copied().collect();
    all.sort_by(f64::total_cmp);
    if all.iter().any(|edge| (edge - start).abs() <= 0.5) {
        return start;
    }
    all.into_iter().find(|edge| *edge > start && *edge <= start + 4.0).unwrap_or(start)
}

pub fn refined_end(end: f64, edges: &Edges) -> f64 {
    let nearest = |candidates: Vec<f64>| candidates.into_iter().min_by(|a, b| (a - end).abs().total_cmp(&(b - end).abs()));
    if let Some(black) = nearest(edges.black_ends.iter().copied().filter(|edge| *edge >= end - 1.0 && *edge <= end + 3.5).collect()) {
        return black;
    }
    nearest(edges.cuts.iter().copied().filter(|edge| *edge >= end - 0.5 && *edge <= end + 1.5).collect()).unwrap_or(end)
}

/// The intro's new bounds in milliseconds, or the old ones when the edges would leave less than a second of it.
pub fn refined(start_ms: u64, end_ms: u64, start: &Edges, end: &Edges) -> (u64, u64) {
    let new_start = refined_start(start_ms as f64 / 1000.0, start);
    let new_end = refined_end(end_ms as f64 / 1000.0, end);
    if new_end <= new_start + 1.0 {
        return (start_ms, end_ms);
    }
    ((new_start * 1000.0).round() as u64, (new_end * 1000.0).round() as u64)
}

/// The cuts and blacks in what ffmpeg's `scdet` and `blackdetect` print for a window read from `offset`.
pub fn edges_from_ffmpeg(output: &str, offset: f64) -> Edges {
    let read = |pattern: &Regex| pattern.captures_iter(output).filter_map(|found| found[1].parse::<f64>().ok()).map(|value| offset + value).collect();
    Edges { cuts: read(&CUT), black_ends: read(&BLACK_END) }
}

/// `segments` with Plex's intro on the picture's edges, read from `input` (a file path or the part's address).
pub async fn sharpen(segments: Vec<Segment>, rating_key: &str, input: &str) -> Vec<Segment> {
    let Some(intro) = segments.iter().find(|segment| segment.kind == Kind::Intro && segment.source == Source::Plex).cloned() else {
        return segments;
    };
    let key = format!("{rating_key}|{}|{}", intro.start_ms, intro.end_ms);
    let cached = KNOWN.lock().ok().and_then(|known| known.get(&key).copied());
    let bounds = match cached {
        Some(bounds) => bounds,
        None => {
            let start = intro.start_ms as f64 / 1000.0;
            let end = intro.end_ms as f64 / 1000.0;
            let (start_edges, end_edges) =
                tokio::join!(edges(input, start - START_BEFORE, START_BEFORE + START_AFTER), edges(input, end - END_BEFORE, END_BEFORE + END_AFTER));
            let (Some(start_edges), Some(end_edges)) = (start_edges, end_edges) else {
                return segments;
            };
            let bounds = refined(intro.start_ms, intro.end_ms, &start_edges, &end_edges);
            if let Ok(mut known) = KNOWN.lock() {
                if known.len() > 20_000 {
                    known.clear();
                }
                known.insert(key, bounds);
            }
            tracing::info!(rating_key, from = ?(intro.start_ms, intro.end_ms), to = ?bounds, "intro sharpened");
            bounds
        }
    };
    segments.into_iter().map(|segment| if segment == intro { Segment { start_ms: bounds.0, end_ms: bounds.1, ..segment } } else { segment }).collect()
}

async fn edges(input: &str, from: f64, length: f64) -> Option<Edges> {
    let offset = from.max(0.0);
    let run = Command::new("ffmpeg")
        .args(["-hide_banner", "-nostdin", "-loglevel", "info", "-ss", &format!("{offset:.3}"), "-t", &format!("{length:.3}"), "-i", input])
        .args(["-an", "-sn", "-dn", "-vf", "scale=160:-2,scdet=t=8,blackdetect=d=0.04:pix_th=0.1", "-f", "null", "-"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(Duration::from_secs(15), run).await.ok()?.ok()?;
    output.status.success().then(|| edges_from_ffmpeg(&String::from_utf8_lossy(&output.stderr), offset))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_offices_intro_moves_onto_the_cut_into_the_titles_and_the_black_after_them() {
        let start = Edges { cuts: vec![137.554], black_ends: vec![] };
        let end = Edges { cuts: vec![158.283], black_ends: vec![158.283] };
        assert_eq!(refined(134_570, 157_935, &start, &end), (137_554, 158_283));
    }

    #[test]
    fn an_intro_that_opens_the_episode_keeps_its_start() {
        let start = Edges { cuts: vec![3.64], black_ends: vec![] };
        let end = Edges { cuts: vec![], black_ends: vec![54.97] };
        assert_eq!(refined(1_240, 54_310, &start, &end), (1_240, 54_970));
    }

    #[test]
    fn nothing_moves_past_its_window() {
        let start = Edges { cuts: vec![140.0], black_ends: vec![] };
        let end = Edges { cuts: vec![], black_ends: vec![163.0] };
        assert_eq!(refined(134_570, 157_935, &start, &end), (134_570, 157_935));
    }

    #[test]
    fn reads_what_ffmpeg_prints() {
        let output = "[scdet @ 0x1] lavfi.scd.score: 31.2, lavfi.scd.time: 4.556\n[blackdetect @ 0x2] black_start:4.431 black_end:4.556 black_duration:0.125";
        let edges = edges_from_ffmpeg(output, 136.251);
        assert!((edges.cuts[0] - 140.807).abs() < 1e-6 && (edges.black_ends[0] - 140.807).abs() < 1e-6);
    }
}
