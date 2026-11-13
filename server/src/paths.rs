//! Where the server keeps its config, database, certificate and the owner's Plex token.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The server's folder: `$CRUCIBLE_SERVER_HOME`, else `~/.config/crucible-server` on Linux and
/// `~/Library/Application Support/crucible-server` on macOS.
#[derive(Clone, Debug)]
pub struct Paths {
    pub root: PathBuf,
}

impl Paths {
    pub fn discover() -> io::Result<Self> {
        if let Some(home) = std::env::var_os("CRUCIBLE_SERVER_HOME") {
            return Ok(Paths { root: PathBuf::from(home) });
        }
        let base = dirs::config_dir().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no config folder for this user"))?;
        Ok(Paths { root: base.join("crucible-server") })
    }

    pub fn at(root: &Path) -> Self {
        Paths { root: root.to_path_buf() }
    }

    /// Creates the folder, readable only by this user.
    pub fn ensure(&self) -> io::Result<()> {
        fs::create_dir_all(&self.root)?;
        restrict(&self.root, 0o700)
    }

    pub fn config(&self) -> PathBuf {
        self.root.join("config.toml")
    }

    pub fn database(&self) -> PathBuf {
        self.root.join("crucible-server.sqlite")
    }

    pub fn certificate(&self) -> PathBuf {
        self.root.join("certificate.pem")
    }

    pub fn private_key(&self) -> PathBuf {
        self.root.join("private-key.pem")
    }

    pub fn plex_token(&self) -> PathBuf {
        self.root.join("plex-token")
    }

    /// The key a model service asks for, when the owner chose one that needs it, kept with the address it was given
    /// for. Kept out of `config.toml` so the config can be shown and shared without it.
    pub fn model_key(&self) -> PathBuf {
        self.root.join("model-key")
    }

    /// The kept key, when it was given for the model server at `url`. A key kept for another address is never
    /// returned, so pointing the config elsewhere by hand cannot send it there.
    pub fn model_key_for(&self, url: &str) -> Option<String> {
        let kept: KeptKey = toml::from_str(&fs::read_to_string(self.model_key()).ok()?).ok()?;
        (same_address(&kept.address, url) && !kept.key.trim().is_empty()).then(|| kept.key.trim().to_string())
    }

    /// Keeps `key` for the model server at `url`, or forgets the kept one when there is none to keep.
    pub fn keep_model_key(&self, url: &str, key: Option<&str>) -> io::Result<()> {
        match key {
            Some(key) => {
                let kept = KeptKey { address: url.trim().to_string(), key: key.trim().to_string() };
                let text = toml::to_string(&kept).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                write_private(&self.model_key(), text.as_bytes())
            }
            None => match fs::remove_file(self.model_key()) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            },
        }
    }

    pub fn log(&self) -> PathBuf {
        self.root.join("crucible-server.log")
    }
}

/// A model key as it is kept: with the address of the service that gave it.
#[derive(serde::Serialize, serde::Deserialize)]
struct KeptKey {
    address: String,
    key: String,
}

/// Whether two addresses name the same model server, ignoring case, surrounding space and a trailing slash.
pub fn same_address(one: &str, other: &str) -> bool {
    let tidy = |url: &str| url.trim().trim_end_matches('/').to_lowercase();
    tidy(one) == tidy(other)
}

/// Writes `bytes` to `path` through a temporary file, readable and writable only by this user.
pub fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("partial");
    {
        let mut file = open_private(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temporary, path)
}

#[cfg(unix)]
fn open_private(path: &Path) -> io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)
}

#[cfg(not(unix))]
fn open_private(path: &Path) -> io::Result<fs::File> {
    fs::OpenOptions::new().write(true).create(true).truncate(true).open(path)
}

#[cfg(unix)]
fn restrict(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn private_files_are_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secret");
        write_private(&path, b"x").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn the_model_key_is_kept_privately_for_one_address_and_forgotten_on_request() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let service = "https://openrouter.ai/api/v1";
        assert_eq!(paths.model_key_for(service), None);
        paths.keep_model_key(service, Some(" sk-test\n")).unwrap();
        assert_eq!(paths.model_key_for(service).as_deref(), Some("sk-test"));
        assert_eq!(paths.model_key_for("https://OpenRouter.ai/api/v1/").as_deref(), Some("sk-test"));
        assert_eq!(paths.model_key_for("https://other.example/v1"), None);
        assert_eq!(paths.model_key_for("http://openrouter.ai/api/v1"), None);
        assert_eq!(fs::metadata(paths.model_key()).unwrap().permissions().mode() & 0o777, 0o600);
        paths.keep_model_key(service, None).unwrap();
        paths.keep_model_key(service, None).unwrap();
        assert_eq!(paths.model_key_for(service), None);
    }
}
