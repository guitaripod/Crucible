//! An episode's dialogue, read from its text subtitles with ffmpeg: the words a summary may rest on, with the time
//! each was said. Lines inside an opening, ending, recap or preview are dropped, as are signs and song lyrics.

use std::path::Path;
use std::process::Stdio;
use std::sync::LazyLock;

use regex::Regex;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::segments::{Kind, Segment};

/// One spoken line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
    pub start_ms: u64,
    pub text: String,
}

#[derive(Debug, thiserror::Error)]
pub enum DialogueError {
    #[error("ffmpeg is not installed")]
    NoFfmpeg,
    #[error("ffmpeg could not read the subtitles: {0}")]
    Ffmpeg(String),
    #[error("the episode has no text subtitles")]
    NoText,
}

static TIMING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\d+):(\d{2}):(\d{2})[,.](\d{3})\s*-->").expect("timing pattern"));
static MARKUP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\{[^}]*\}|<[^>]+>").expect("markup pattern"));
static SONG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[♪♫#~]|[♪♫]$").expect("song pattern"));

/// The lines of an SRT document, without markup, music and sound cues.
pub fn parse_srt(srt: &str) -> Vec<Line> {
    let mut lines = Vec::new();
    let mut current: Option<(u64, Vec<String>)> = None;
    for raw in srt.lines().map(|line| line.trim_end_matches('\r')) {
        if let Some(captures) = TIMING.captures(raw.trim()) {
            if let Some((start, text)) = current.take() {
                push(&mut lines, start, &text);
            }
            let number = |index: usize| captures[index].parse::<u64>().unwrap_or(0);
            let start = ((number(1) * 60 + number(2)) * 60 + number(3)) * 1000 + number(4);
            current = Some((start, Vec::new()));
        } else if raw.trim().is_empty() {
            if let Some((start, text)) = current.take() {
                push(&mut lines, start, &text);
            }
        } else if let Some((_, text)) = current.as_mut() {
            text.push(raw.trim().to_string());
        }
    }
    if let Some((start, text)) = current {
        push(&mut lines, start, &text);
    }
    lines
}

fn push(lines: &mut Vec<Line>, start_ms: u64, text: &[String]) {
    let joined = MARKUP.replace_all(&text.join(" "), "").replace("\\N", " ").replace("\\n", " ");
    let cleaned = joined.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.is_empty()
        || SONG.is_match(&cleaned)
        || (cleaned.starts_with('[') && cleaned.ends_with(']'))
        || (cleaned.starts_with('(') && cleaned.ends_with(')'))
    {
        return;
    }
    if lines.last().is_some_and(|last: &Line| last.text == cleaned) {
        return;
    }
    lines.push(Line { start_ms, text: cleaned });
}

/// The story's lines: everything outside the segments a viewer skips.
pub fn story(lines: Vec<Line>, segments: &[Segment]) -> Vec<Line> {
    lines
        .into_iter()
        .filter(|line| {
            !segments.iter().any(|segment| {
                matches!(segment.kind, Kind::Intro | Kind::Ending | Kind::Recap | Kind::Preview | Kind::Credits)
                    && line.start_ms >= segment.start_ms
                    && line.start_ms < segment.end_ms
            })
        })
        .collect()
}

/// The lines, cut to fit `max_chars` of transcript: one-word interjections go first, then every other line evenly
/// across the episode, so the end of the story is never what is lost.
pub fn fit(lines: Vec<Line>, max_chars: usize) -> Vec<Line> {
    let size = |lines: &[Line]| lines.iter().map(|line| line.text.len() + 9).sum::<usize>();
    if size(&lines) <= max_chars {
        return lines;
    }
    let mut kept: Vec<Line> = lines.into_iter().filter(|line| line.text.split_whitespace().count() > 2).collect();
    while size(&kept) > max_chars && kept.len() > 1 {
        let ratio = max_chars as f64 / size(&kept) as f64;
        let target = ((kept.len() as f64 * ratio).floor() as usize).clamp(1, kept.len() - 1);
        let step = kept.len() as f64 / target as f64;
        kept = (0..target).map(|index| kept[((index as f64 * step) as usize).min(kept.len() - 1)].clone()).collect();
    }
    kept
}

/// "12:34", how a summary cites a moment.
pub fn timestamp(ms: u64) -> String {
    let seconds = ms / 1000;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

/// The transcript a model reads: one "[12:34] line" per line.
pub fn transcript(lines: &[Line]) -> String {
    lines.iter().map(|line| format!("[{}] {}", timestamp(line.start_ms), line.text)).collect::<Vec<_>>().join("\n")
}

/// The subtitle stream at `stream_index` (the file's own stream number, as Plex reports it) of a file on this
/// machine, as SRT.
pub async fn extract_local(file: &Path, stream_index: u64) -> Result<String, DialogueError> {
    let mut command = Command::new("ffmpeg");
    command.args(["-nostdin", "-loglevel", "error", "-i"]).arg(file).args(["-map", &format!("0:{stream_index}"), "-f", "srt", "-"]);
    run(command, None).await
}

/// The same from a file streamed from Plex, for a companion that is not on the media's machine.
pub async fn extract_streamed(response: reqwest::Response, stream_index: u64) -> Result<String, DialogueError> {
    let mut command = Command::new("ffmpeg");
    command.args(["-loglevel", "error", "-i", "pipe:0", "-map", &format!("0:{stream_index}"), "-f", "srt", "-"]);
    run(command, Some(response)).await
}

/// An external subtitle file (SRT, ASS, WebVTT) converted to SRT.
pub async fn convert(bytes: Vec<u8>) -> Result<String, DialogueError> {
    let mut command = Command::new("ffmpeg");
    command.args(["-loglevel", "error", "-i", "pipe:0", "-f", "srt", "-"]);
    run_with_bytes(command, bytes).await
}

async fn run(mut command: Command, input: Option<reqwest::Response>) -> Result<String, DialogueError> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    let mut child = command.spawn().map_err(|_| DialogueError::NoFfmpeg)?;
    if let (Some(mut response), Some(mut stdin)) = (input, child.stdin.take()) {
        tokio::spawn(async move {
            while let Ok(Some(chunk)) = response.chunk().await {
                if stdin.write_all(&chunk).await.is_err() {
                    break;
                }
            }
        });
    }
    let output = child.wait_with_output().await.map_err(|error| DialogueError::Ffmpeg(error.to_string()))?;
    finish(output)
}

async fn run_with_bytes(mut command: Command, bytes: Vec<u8>) -> Result<String, DialogueError> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(Stdio::piped());
    let mut child = command.spawn().map_err(|_| DialogueError::NoFfmpeg)?;
    if let Some(mut stdin) = child.stdin.take() {
        tokio::spawn(async move {
            let _ = stdin.write_all(&bytes).await;
        });
    }
    let output = child.wait_with_output().await.map_err(|error| DialogueError::Ffmpeg(error.to_string()))?;
    finish(output)
}

fn finish(output: std::process::Output) -> Result<String, DialogueError> {
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("").to_string();
        return Err(DialogueError::Ffmpeg(message));
    }
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    if text.trim().is_empty() {
        return Err(DialogueError::NoText);
    }
    Ok(text)
}

/// What ffprobe says about a file: its text subtitle streams (stream number, language), its chapters and duration.
pub struct Probe {
    pub subtitles: Vec<(u64, String)>,
    pub chapters: Vec<crate::segments::Chapter>,
    pub duration_ms: u64,
}

pub async fn probe(file: &Path) -> Result<Probe, DialogueError> {
    let output = Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language:format=duration", "-show_chapters", "-of", "json"])
        .arg(file)
        .output()
        .await
        .map_err(|_| DialogueError::NoFfmpeg)?;
    if !output.status.success() {
        return Err(DialogueError::Ffmpeg(String::from_utf8_lossy(&output.stderr).trim().to_string()));
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).map_err(|error| DialogueError::Ffmpeg(error.to_string()))?;
    let text_codecs = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"];
    let subtitles = json["streams"]
        .as_array()
        .map(|streams| {
            streams
                .iter()
                .filter(|stream| stream["codec_type"] == "subtitle" && text_codecs.contains(&stream["codec_name"].as_str().unwrap_or("")))
                .filter_map(|stream| Some((stream["index"].as_u64()?, stream["tags"]["language"].as_str().unwrap_or("und").to_string())))
                .collect()
        })
        .unwrap_or_default();
    let seconds = |value: &serde_json::Value| value.as_str().and_then(|text| text.parse::<f64>().ok()).map_or(0, |seconds| (seconds * 1000.0) as u64);
    let chapters = json["chapters"]
        .as_array()
        .map(|chapters| {
            chapters
                .iter()
                .map(|chapter| crate::segments::Chapter {
                    title: chapter["tags"]["title"].as_str().unwrap_or("").to_string(),
                    start_ms: seconds(&chapter["start_time"]),
                    end_ms: seconds(&chapter["end_time"]),
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Probe { subtitles, chapters, duration_ms: seconds(&json["format"]["duration"]) })
}

/// The story's dialogue of a file on this machine, from its first English (else first) text subtitle stream.
pub async fn local_story(file: &Path) -> Result<Vec<Line>, DialogueError> {
    let probe = probe(file).await?;
    let stream =
        probe.subtitles.iter().find(|(_, language)| language == "eng").or(probe.subtitles.first()).map(|(index, _)| *index).ok_or(DialogueError::NoText)?;
    let lines = parse_srt(&extract_local(file, stream).await?);
    let segments = crate::segments::make(&[], &probe.chapters, probe.duration_ms);
    Ok(story(lines, &segments))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::segments::Source;

    const SRT: &str = "1\r\n00:00:05,000 --> 00:00:07,000\r\n♪ Chala head chala ♪\r\n\r\n2\r\n00:01:40,500 --> 00:01:42,000\r\n{\\an8}Previously on Dragon Ball Super...\r\n\r\n3\r\n00:03:01,250 --> 00:03:03,000\r\n<i>Vegeta, wait!</i>\r\n\r\n4\r\n00:03:04,000 --> 00:03:05,000\r\n[door slams]\r\n\r\n5\r\n00:03:06,000 --> 00:03:08,000\r\nI'll surpass you,\r\nKakarot.\r\n";

    #[test]
    fn reads_lines_without_markup_songs_or_cues() {
        let lines = parse_srt(SRT);
        assert_eq!(
            lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Previously on Dragon Ball Super...", "Vegeta, wait!", "I'll surpass you, Kakarot."]
        );
        assert_eq!(lines[1].start_ms, 181_250);
    }

    #[test]
    fn fitting_keeps_the_whole_episode_in_view() {
        let lines: Vec<Line> = (0..1000).map(|n| Line { start_ms: n * 1000, text: format!("line number {n} is here") }).collect();
        let fitted = fit(lines, 4000);
        assert!(fitted.iter().map(|l| l.text.len() + 9).sum::<usize>() <= 4000);
        assert!(fitted.first().unwrap().start_ms < 10_000);
        assert!(fitted.last().unwrap().start_ms > 950_000);
    }

    #[test]
    fn the_story_leaves_out_what_viewers_skip() {
        let recap = Segment { kind: Kind::Recap, start_ms: 90_000, end_ms: 140_000, source: Source::Chapter };
        let lines = story(parse_srt(SRT), &[recap]);
        assert_eq!(lines.len(), 2);
        assert_eq!(transcript(&lines[..1]), "[3:01] Vegeta, wait!");
    }
}
