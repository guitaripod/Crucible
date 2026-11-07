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

    pub fn log(&self) -> PathBuf {
        self.root.join("crucible-server.log")
    }
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
}
