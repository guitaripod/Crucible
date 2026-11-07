//! What the owner sees in a terminal: questions with a default, and the pairing QR code.

use std::io::{self, BufRead, Write};

use qrcode::render::unicode::Dense1x2;
use qrcode::QrCode;

/// The QR code for `text`, drawn with half blocks so it fits an 80-column terminal.
pub fn qr(text: &str) -> String {
    match QrCode::new(text.as_bytes()) {
        Ok(code) => code.render::<Dense1x2>().dark_color(Dense1x2::Light).light_color(Dense1x2::Dark).quiet_zone(true).build(),
        Err(_) => String::new(),
    }
}

/// Asks `question`, showing `default`, and returns the answer or the default for an empty line.
pub fn ask(question: &str, default: &str) -> String {
    print!("{question} [{default}] ");
    let _ = io::stdout().flush();
    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line).is_err() {
        return default.into();
    }
    let answer = line.trim();
    if answer.is_empty() {
        default.into()
    } else {
        answer.into()
    }
}

/// A yes-or-no question; Enter takes `default`.
pub fn confirm(question: &str, default: bool) -> bool {
    let answer = ask(question, if default { "Y/n" } else { "y/N" });
    match answer.to_lowercase().as_str() {
        "y" | "yes" => true,
        "n" | "no" => false,
        _ => default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_a_qr_code() {
        let drawn = qr("crucible://pair?v=1");
        assert!(drawn.lines().count() > 10);
        assert!(drawn.contains('█') || drawn.contains('▀') || drawn.contains('▄'));
    }
}
