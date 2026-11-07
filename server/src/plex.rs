//! The Plex Media Server this companion serves, always asked as the person making the request, so restricted
//! profiles see only what Plex already lets them see.

use std::time::Duration;

use reqwest::StatusCode;
use serde::Deserialize;

use crate::segments::{Chapter, Marker};

pub const PRODUCT: &str = "Crucible Server";

/// What went wrong talking to Plex.
#[derive(Debug, thiserror::Error)]
pub enum PlexError {
    #[error("Plex at {0} did not answer: {1}")]
    Unreachable(String, String),
    #[error("Plex refused the token")]
    Unauthorized,
    #[error("Plex has no item {0}")]
    NotFound(String),
    #[error("Plex answered {0}")]
    Status(u16),
    #[error("Plex sent something unexpected: {0}")]
    Decode(String),
}

#[derive(Clone)]
pub struct Plex {
    base: String,
    http: reqwest::Client,
    client_id: String,
}

#[derive(Debug, Deserialize)]
struct Envelope<T> {
    #[serde(rename = "MediaContainer")]
    container: T,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdentityContainer {
    #[serde(default)]
    machine_identifier: String,
    #[serde(default)]
    version: String,
}

#[derive(Debug, Default, Deserialize)]
struct MetadataContainer {
    #[serde(rename = "Metadata", default)]
    metadata: Vec<Item>,
}

/// One item as Plex describes it, with only what the companion reads.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    #[serde(default)]
    pub rating_key: String,
    #[serde(default, rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub grandparent_title: Option<String>,
    #[serde(default)]
    pub grandparent_rating_key: Option<String>,
    #[serde(default)]
    pub parent_index: Option<i64>,
    #[serde(default)]
    pub index: Option<i64>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub duration: Option<u64>,
    #[serde(rename = "Marker", default)]
    pub markers: Vec<PlexMarker>,
    #[serde(rename = "Chapter", default)]
    pub chapters: Vec<PlexChapter>,
    #[serde(rename = "Media", default)]
    pub media: Vec<Media>,
    #[serde(rename = "Role", default)]
    pub roles: Vec<Role>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexMarker {
    #[serde(default, rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub start_time_offset: u64,
    #[serde(default)]
    pub end_time_offset: u64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlexChapter {
    #[serde(default)]
    pub tag: Option<String>,
    #[serde(default)]
    pub start_time_offset: u64,
    #[serde(default)]
    pub end_time_offset: u64,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Media {
    #[serde(rename = "Part", default)]
    pub parts: Vec<Part>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Part {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub file: Option<String>,
    #[serde(rename = "Stream", default)]
    pub streams: Vec<Stream>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stream {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub stream_type: u8,
    #[serde(default)]
    pub index: Option<u64>,
    #[serde(default)]
    pub codec: Option<String>,
    #[serde(default)]
    pub language_code: Option<String>,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub forced: Option<bool>,
    #[serde(default)]
    pub title: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Role {
    #[serde(default)]
    pub tag: String,
    #[serde(default)]
    pub role: Option<String>,
}

impl Item {
    pub fn plex_markers(&self) -> Vec<Marker> {
        self.markers.iter().map(|marker| Marker { kind: marker.kind.clone(), start_ms: marker.start_time_offset, end_ms: marker.end_time_offset }).collect()
    }

    pub fn plex_chapters(&self) -> Vec<Chapter> {
        self.chapters
            .iter()
            .map(|chapter| Chapter { title: chapter.tag.clone().unwrap_or_default(), start_ms: chapter.start_time_offset, end_ms: chapter.end_time_offset })
            .collect()
    }

    /// The first file of the item, which is what plays.
    pub fn part(&self) -> Option<&Part> {
        self.media.first().and_then(|media| media.parts.first())
    }

    /// "S1 · E41", or the title when the item is not an episode.
    pub fn label(&self) -> String {
        match (self.parent_index, self.index) {
            (Some(season), Some(episode)) => format!("S{season} · E{episode}"),
            _ => self.title.clone(),
        }
    }
}

impl Stream {
    pub fn is_subtitle(&self) -> bool {
        self.stream_type == 3
    }

    /// Whether the subtitle is text the companion can read, rather than pictures of text.
    pub fn is_text(&self) -> bool {
        matches!(self.codec.as_deref().unwrap_or(""), "srt" | "subrip" | "ass" | "ssa" | "mov_text" | "webvtt" | "vtt" | "text" | "smi")
    }
}

impl Plex {
    pub fn new(base: &str, client_id: &str) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(30)).connect_timeout(Duration::from_secs(5)).build().expect("an HTTP client builds");
        Plex { base: base.trim_end_matches('/').to_string(), http, client_id: client_id.into() }
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    fn request(&self, path: &str, token: Option<&str>) -> reqwest::RequestBuilder {
        let mut request = self
            .http
            .get(format!("{}{}", self.base, path))
            .header("Accept", "application/json")
            .header("X-Plex-Product", PRODUCT)
            .header("X-Plex-Client-Identifier", &self.client_id);
        if let Some(token) = token {
            request = request.header("X-Plex-Token", token);
        }
        request
    }

    async fn send(&self, path: &str, token: Option<&str>) -> Result<reqwest::Response, PlexError> {
        self.request(path, token).send().await.map_err(|error| PlexError::Unreachable(self.base.clone(), error.to_string()))
    }

    /// The server's machine identifier and version, which Plex gives without a token.
    pub async fn identity(&self) -> Result<(String, String), PlexError> {
        let response = self.send("/identity", None).await?;
        if !response.status().is_success() {
            return Err(PlexError::Status(response.status().as_u16()));
        }
        let body: Envelope<IdentityContainer> = response.json().await.map_err(|error| PlexError::Decode(error.to_string()))?;
        Ok((body.container.machine_identifier, body.container.version))
    }

    /// The negative control: Plex must refuse a request with no token and one with a made-up token, or anyone on the
    /// network could read the library through this companion.
    pub async fn refuses_strangers(&self) -> Result<bool, PlexError> {
        let anonymous = self.send("/library/sections", None).await?.status();
        let made_up = self.send("/library/sections", Some(&crate::pairing::new_device_token())).await?.status();
        Ok(anonymous == StatusCode::UNAUTHORIZED && made_up == StatusCode::UNAUTHORIZED)
    }

    /// Whether Plex accepts this token for this server.
    pub async fn accepts(&self, token: &str) -> Result<bool, PlexError> {
        let status = self.send("/library/sections", Some(token)).await?.status();
        match status {
            StatusCode::OK => Ok(true),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Ok(false),
            other => Err(PlexError::Status(other.as_u16())),
        }
    }

    async fn container(&self, path: &str, token: &str) -> Result<MetadataContainer, PlexError> {
        let response = self.send(path, Some(token)).await?;
        match response.status() {
            StatusCode::OK => {}
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => return Err(PlexError::Unauthorized),
            StatusCode::NOT_FOUND => return Err(PlexError::NotFound(path.into())),
            other => return Err(PlexError::Status(other.as_u16())),
        }
        let body: Envelope<MetadataContainer> = response.json().await.map_err(|error| PlexError::Decode(error.to_string()))?;
        Ok(body.container)
    }

    /// One item with its markers, chapters, files and streams, as the caller may see it.
    pub async fn item(&self, rating_key: &str, token: &str) -> Result<Item, PlexError> {
        let key = sanitize_key(rating_key).ok_or_else(|| PlexError::NotFound(rating_key.into()))?;
        let path = format!("/library/metadata/{key}?includeChapters=1&includeMarkers=1");
        self.container(&path, token).await?.metadata.into_iter().next().ok_or(PlexError::NotFound(key.into()))
    }

    /// Every episode of a show, in Plex's order.
    pub async fn episodes(&self, show_key: &str, token: &str) -> Result<Vec<Item>, PlexError> {
        let key = sanitize_key(show_key).ok_or_else(|| PlexError::NotFound(show_key.into()))?;
        Ok(self.container(&format!("/library/metadata/{key}/allLeaves"), token).await?.metadata)
    }

    /// The bytes behind a Plex path such as an external subtitle's `/library/streams/{id}`.
    pub async fn download(&self, path: &str, token: &str) -> Result<Vec<u8>, PlexError> {
        if !path.starts_with("/library/") {
            return Err(PlexError::NotFound(path.into()));
        }
        let response = self.send(path, Some(token)).await?;
        if !response.status().is_success() {
            return Err(PlexError::Status(response.status().as_u16()));
        }
        Ok(response.bytes().await.map_err(|error| PlexError::Decode(error.to_string()))?.to_vec())
    }

    /// A streaming request for a file Plex serves, for a companion on another machine than the media.
    pub fn file_request(&self, part_key: &str, token: &str) -> Option<reqwest::RequestBuilder> {
        part_key.starts_with("/library/parts/").then(|| self.request(part_key, Some(token)).timeout(Duration::from_secs(3600)))
    }
}

/// A rating key is digits; anything else never reaches a Plex URL.
pub fn sanitize_key(key: &str) -> Option<&str> {
    (!key.is_empty() && key.len() <= 20 && key.bytes().all(|byte| byte.is_ascii_digit())).then_some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rating_keys_are_digits_only() {
        assert_eq!(sanitize_key("4012"), Some("4012"));
        assert_eq!(sanitize_key("../accounts"), None);
        assert_eq!(sanitize_key(""), None);
        assert_eq!(sanitize_key("12?x=1"), None);
    }

    #[test]
    fn decodes_an_episode_with_markers_chapters_and_streams() {
        let json = r#"{"MediaContainer":{"Metadata":[{"ratingKey":"41","type":"episode","title":"A","grandparentTitle":"Show","parentIndex":1,"index":41,
            "duration":1410000,"summary":"Goku trains.",
            "Marker":[{"type":"intro","startTimeOffset":0,"endTimeOffset":90000}],
            "Chapter":[{"tag":"Recap","startTimeOffset":90000,"endTimeOffset":140000}],
            "Media":[{"Part":[{"id":7,"key":"/library/parts/7/1/file.mkv","file":"/data/a.mkv",
              "Stream":[{"id":9,"streamType":3,"index":2,"codec":"ass","languageCode":"eng"}]}]}],
            "Role":[{"tag":"Masako Nozawa","role":"Goku"}]}]}}"#;
        let container: Envelope<MetadataContainer> = serde_json::from_str(json).unwrap();
        let item = &container.container.metadata[0];
        assert_eq!(item.label(), "S1 · E41");
        assert_eq!(item.plex_markers()[0].end_ms, 90_000);
        assert_eq!(item.plex_chapters()[0].title, "Recap");
        let stream = &item.part().unwrap().streams[0];
        assert!(stream.is_subtitle() && stream.is_text());
        assert_eq!(item.roles[0].role.as_deref(), Some("Goku"));
    }
}
