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

/// The model that writes recaps and answers: any OpenAI-compatible endpoint, on this machine or the owner's tailnet,
/// or a hosted service the owner chose.
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
    /// The host outside the owner's networks they agreed to send to, when the model is at one. A model outside that
    /// was put in the config any other way than through that agreement is not used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_agreed: Option<String>,
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
            model_agreed: None,
        }
    }

    pub fn load(path: &Path) -> io::Result<Self> {
        let text = fs::read_to_string(path)?;
        toml::from_str(&text).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    /// The config of a server that was set up, or a sentence saying to set it up, for commands that need one.
    pub fn load_set_up(path: &Path) -> Result<Self, String> {
        match Config::load(path) {
            Ok(config) => Ok(config),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Err("Crucible Server is not set up yet. Run crucible-server setup first.".into()),
            Err(error) => Err(format!("{} cannot be read: {error}. Run crucible-server setup again.", path.display())),
        }
    }

    /// Sets the model and records the agreement that goes with it: the host for a model outside the owner's networks,
    /// nothing for one inside them. Called only once the owner has agreed, or chose a model of their own.
    pub fn use_model(&mut self, model: Option<Model>) {
        self.model_agreed = model.as_ref().and_then(|model| match crate::net::model_place(&model.url) {
            crate::net::ModelPlace::Outside(host) => Some(host),
            crate::net::ModelPlace::Own => None,
        });
        self.model = model;
    }

    /// The model to write with: the one set, unless it is outside the owner's networks and they never agreed to its
    /// host, as when a config was edited by hand or copied from another machine.
    pub fn usable_model(&self) -> Result<Option<&Model>, String> {
        let Some(model) = &self.model else { return Ok(None) };
        match crate::net::model_place(&model.url) {
            crate::net::ModelPlace::Outside(host) if self.model_agreed.as_deref() != Some(host.as_str()) => Err(format!(
                "the model at {host} is outside your network and was never agreed to: set it with crucible-server model --url {} --name {}",
                model.url, model.name
            )),
            _ => Ok(Some(model)),
        }
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
    fn a_model_outside_is_used_only_with_the_agreement_recorded_for_its_host() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let outside = Model { url: "https://openrouter.ai/api/v1".into(), name: "writer".into(), context: 8192 };
        let mut config = Config::new("nas");
        config.use_model(Some(outside.clone()));
        assert_eq!(config.model_agreed.as_deref(), Some("openrouter.ai"));
        assert_eq!(config.usable_model().unwrap(), Some(&outside));
        config.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), config);

        config.model = Some(Model { url: "https://other.example/v1".into(), ..outside.clone() });
        assert!(config.usable_model().unwrap_err().contains("other.example is outside your network"));
        config.model_agreed = None;
        config.model = Some(outside);
        assert!(config.usable_model().is_err());

        let own = Model { url: "http://127.0.0.1:8081/v1".into(), name: "writer".into(), context: 8192 };
        config.use_model(Some(own.clone()));
        assert_eq!((config.model_agreed.clone(), config.usable_model().unwrap()), (None, Some(&own)));
        config.use_model(None);
        assert_eq!(config.usable_model().unwrap(), None);
    }

    #[test]
    fn maps_plex_paths_to_local_ones() {
        let mut config = Config::new("nas");
        config.path_map.push(PathMap { plex: "D:\\Anime".into(), local: "/volume1/anime".into() });
        assert_eq!(config.local_path("D:\\Anime\\Dragon Ball Super\\01.mkv"), PathBuf::from("/volume1/anime/Dragon Ball Super/01.mkv"));
        assert_eq!(config.local_path("/data/tv/a.mkv"), PathBuf::from("/data/tv/a.mkv"));
    }
}
