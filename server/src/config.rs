//! `config.toml`: where Plex is, who may use the server, which libraries it reads, and which model writes.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The port the server listens on unless the config says otherwise, next to Plex's 32400.
pub const DEFAULT_PORT: u16 = 32500;

/// Who besides the owner may pair a device and use the server.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Policy {
    OnlyMe,
    #[default]
    MyPlexHome,
    Everyone,
}

/// The model that writes recaps and answers: any OpenAI-compatible endpoint on this machine or the owner's tailnet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Model {
    pub url: String,
    pub name: String,
    #[serde(default = "default_context")]
    pub context: u32,
}

/// The context window assumed when the model server does not say: small enough for any model worth using.
pub const DEFAULT_CONTEXT: u32 = 8192;

fn default_context() -> u32 {
    DEFAULT_CONTEXT
}

/// Everything `setup` asks once and `serve` reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    pub name: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_plex_url")]
    pub plex_url: String,
    #[serde(default)]
    pub machine_identifier: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub policy: Policy,
    #[serde(default)]
    pub libraries: Vec<String>,
    #[serde(default)]
    pub path_map: Vec<PathMap>,
    #[serde(default)]
    pub model: Option<Model>,
}

/// Where a folder Plex reports lives on this machine, when the two differ (Plex in Docker, or on Windows).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathMap {
    pub plex: String,
    pub local: String,
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

fn default_plex_url() -> String {
    "http://127.0.0.1:32400".into()
}

impl Config {
    /// A fresh config named after this machine.
    pub fn new(name: &str) -> Self {
        Config {
            name: name.into(),
            port: DEFAULT_PORT,
            plex_url: default_plex_url(),
            machine_identifier: String::new(),
            owner: String::new(),
            policy: Policy::default(),
            libraries: Vec::new(),
            path_map: Vec::new(),
            model: None,
        }
    }

    pub fn load(path: &Path) -> io::Result<Self> {
        let text = fs::read_to_string(path)?;
        toml::from_str(&text).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    /// Writes the config readable only by this user, since it names the owner and the model host.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let text = toml::to_string_pretty(self).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        crate::paths::write_private(path, text.as_bytes())
    }

    /// The local path of a file Plex reports, through the first `path_map` entry whose Plex prefix it starts with.
    pub fn local_path(&self, plex_path: &str) -> PathBuf {
        for map in &self.path_map {
            if let Some(rest) = plex_path.strip_prefix(&map.plex) {
                let rest = rest.trim_start_matches(['/', '\\']).replace('\\', "/");
                return Path::new(&map.local).join(rest);
            }
        }
        PathBuf::from(plex_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_toml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut config = Config::new("arch");
        config.model = Some(Model { url: "http://127.0.0.1:8081/v1".into(), name: "gemma4-26b-a4b-gguf".into(), context: 8192 });
        config.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), config);
    }

    #[test]
    fn maps_plex_paths_to_local_ones() {
        let mut config = Config::new("nas");
        config.path_map.push(PathMap { plex: "D:\\Anime".into(), local: "/volume1/anime".into() });
        assert_eq!(config.local_path("D:\\Anime\\Dragon Ball Super\\01.mkv"), PathBuf::from("/volume1/anime/Dragon Ball Super/01.mkv"));
        assert_eq!(config.local_path("/data/tv/a.mkv"), PathBuf::from("/data/tv/a.mkv"));
    }
}
