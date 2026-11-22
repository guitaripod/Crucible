//! The programs setup leans on: ffmpeg, which lands skips on the picture's edges and reads subtitles for recaps, and the
//! system's way of opening a link in the browser.

use std::process::{Command, Stdio};

/// Whether ffmpeg runs here.
pub fn has_ffmpeg() -> bool {
    Command::new("ffmpeg").arg("-version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|status| status.success())
}

/// The command that installs ffmpeg with the package manager this system has, or nil when none is known.
pub fn ffmpeg_install_command() -> Option<Vec<&'static str>> {
    let has = |program: &str| Command::new("sh").args(["-c", &format!("command -v {program}")]).stdout(Stdio::null()).status().is_ok_and(|s| s.success());
    let sudo = |rest: &[&'static str]| -> Vec<&'static str> {
        let root = Command::new("id").arg("-u").output().ok().is_some_and(|out| String::from_utf8_lossy(&out.stdout).trim() == "0");
        if root {
            rest.to_vec()
        } else {
            [&["sudo"], rest].concat()
        }
    };
    if cfg!(target_os = "macos") {
        return has("brew").then(|| vec!["brew", "install", "ffmpeg"]);
    }
    if has("pacman") {
        Some(sudo(&["pacman", "-S", "--needed", "--noconfirm", "ffmpeg"]))
    } else if has("apt-get") {
        Some(sudo(&["apt-get", "install", "-y", "ffmpeg"]))
    } else if has("dnf") {
        Some(sudo(&["dnf", "install", "-y", "ffmpeg"]))
    } else if has("zypper") {
        Some(sudo(&["zypper", "--non-interactive", "install", "ffmpeg"]))
    } else if has("apk") {
        Some(sudo(&["apk", "add", "ffmpeg"]))
    } else {
        None
    }
}

/// Runs `command` in this terminal, so a password prompt reaches the owner; true when it succeeded.
pub fn run_in_terminal(command: &[&str]) -> bool {
    let Some((program, arguments)) = command.split_first() else { return false };
    Command::new(program).args(arguments).status().is_ok_and(|status| status.success())
}

/// Opens `url` in the browser when this session has a screen; quietly does nothing over SSH or in a container.
pub fn open_in_browser(url: &str) {
    if std::env::var_os("SSH_CONNECTION").is_some() {
        return;
    }
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else if std::env::var_os("DISPLAY").is_some() || std::env::var_os("WAYLAND_DISPLAY").is_some() {
        "xdg-open"
    } else {
        return;
    };
    let _ = Command::new(opener).arg(url).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
}
