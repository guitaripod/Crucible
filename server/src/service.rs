//! Keeping the server running without a terminal: a systemd user unit on Linux, a launchd agent on macOS.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const UNIT: &str = "crucible-server.service";
pub const LABEL: &str = "cc.midgarcorp.crucible-server";

/// The systemd user unit that runs `serve`.
pub fn systemd_unit(executable: &Path, home: &Path) -> String {
    format!(
        "[Unit]\nDescription=Crucible Server, the companion to Plex for Crucible\nAfter=network-online.target\nWants=network-online.target\n\n\
[Service]\nExecStart={} serve\nEnvironment=CRUCIBLE_SERVER_HOME={}\nRestart=on-failure\nRestartSec=5\nNice=5\n\n[Install]\nWantedBy=default.target\n",
        executable.display(),
        home.display()
    )
}

/// The launchd agent that runs `serve` at login and keeps it alive.
pub fn launchd_plist(executable: &Path, home: &Path, log: &Path) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
<plist version=\"1.0\">\n<dict>\n  <key>Label</key><string>{LABEL}</string>\n  <key>ProgramArguments</key><array><string>{}</string><string>serve</string></array>\n\
  <key>EnvironmentVariables</key><dict><key>CRUCIBLE_SERVER_HOME</key><string>{}</string><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>\n\
  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n  <key>ProcessType</key><string>Background</string>\n\
  <key>StandardOutPath</key><string>{}</string>\n  <key>StandardErrorPath</key><string>{}</string>\n</dict>\n</plist>\n",
        executable.display(),
        home.display(),
        log.display(),
        log.display()
    )
}

fn run(program: &str, arguments: &[&str]) -> io::Result<()> {
    let status = Command::new(program).args(arguments).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{program} {} failed", arguments.join(" "))))
    }
}

/// Installs and starts the service for this user; returns where its definition went.
pub fn install(home: &Path, log: &Path) -> io::Result<PathBuf> {
    let executable = std::env::current_exe()?;
    match std::env::consts::OS {
        "linux" => {
            let folder = dirs::config_dir().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no config folder"))?.join("systemd/user");
            fs::create_dir_all(&folder)?;
            let unit = folder.join(UNIT);
            fs::write(&unit, systemd_unit(&executable, home))?;
            run("systemctl", &["--user", "daemon-reload"])?;
            run("systemctl", &["--user", "enable", "--now", UNIT])?;
            run("systemctl", &["--user", "restart", UNIT])?;
            let _ = Command::new("loginctl").args(["enable-linger"]).status();
            Ok(unit)
        }
        "macos" => {
            let folder = dirs::home_dir().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no home folder"))?.join("Library/LaunchAgents");
            fs::create_dir_all(&folder)?;
            let plist = folder.join(format!("{LABEL}.plist"));
            let domain = format!("gui/{}", uid());
            let _ = Command::new("launchctl").args(["bootout", &format!("{domain}/{LABEL}")]).status();
            fs::write(&plist, launchd_plist(&executable, home, log))?;
            run("launchctl", &["bootstrap", &domain, &plist.to_string_lossy()])?;
            Ok(plist)
        }
        _ => Err(io::Error::new(io::ErrorKind::Unsupported, "Run `crucible-server serve` from your system's service manager.")),
    }
}

/// Stops and removes the service.
pub fn uninstall() -> io::Result<()> {
    match std::env::consts::OS {
        "linux" => {
            let _ = run("systemctl", &["--user", "disable", "--now", UNIT]);
            if let Some(folder) = dirs::config_dir() {
                let _ = fs::remove_file(folder.join("systemd/user").join(UNIT));
            }
            run("systemctl", &["--user", "daemon-reload"])
        }
        "macos" => {
            let _ = Command::new("launchctl").args(["bootout", &format!("gui/{}/{LABEL}", uid())]).status();
            if let Some(home) = dirs::home_dir() {
                let _ = fs::remove_file(home.join("Library/LaunchAgents").join(format!("{LABEL}.plist")));
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn uid() -> String {
    Command::new("id").arg("-u").output().map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string()).unwrap_or_else(|_| "501".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_unit_runs_serve_with_its_home() {
        let unit = systemd_unit(Path::new("/usr/bin/crucible-server"), Path::new("/home/m/.config/crucible-server"));
        assert!(unit.contains("ExecStart=/usr/bin/crucible-server serve\n"));
        assert!(unit.contains("Environment=CRUCIBLE_SERVER_HOME=/home/m/.config/crucible-server\n"));
        let plist = launchd_plist(Path::new("/opt/homebrew/bin/crucible-server"), Path::new("/h"), Path::new("/h/log"));
        assert!(plist.contains("<string>serve</string>") && plist.contains(LABEL));
    }
}
