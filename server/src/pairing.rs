//! Pairing a device once. The owner's terminal shows a single-use 128-bit secret (as a QR code or a typed code);
//! discovery never carries it. The server proves it knows the secret first, keyed to the fingerprint of the TLS
//! certificate the device actually sees, so a host impersonating the Plex machine learns nothing; only then does the
//! device prove it and receive its token. A paired device may also hand over a secret another device made and showed
//! (an Apple TV's QR code); that secret pairs one device, and only one the server's policy admits for its Plex account.
//! A used secret stays refused for a day while the server runs; handing one on takes a device the policy admits, which
//! could hand on a fresh secret anyway.

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::{Digest, Sha256};

/// How long a shown secret works.
pub const LIFETIME: Duration = Duration::from_secs(600);
/// Wrong proofs a secret survives before it is burned.
const ATTEMPTS: u32 = 5;
/// Secrets that may be open at once.
const OPEN_LIMIT: usize = 8;
/// Open secrets one paired device may have handed on at once; a further one replaces its oldest.
const HANDED_PER_DEVICE: usize = 2;
/// How long a used secret stays refused, far longer than any secret stays open.
const SPENT_FOR: Duration = Duration::from_secs(24 * 60 * 60);
/// Used secrets remembered at most.
const SPENT_LIMIT: usize = 4096;
/// Exchanges one secret keeps at once, so a device that saw a secret it may not use cannot crowd out the one that may.
const EXCHANGES: usize = 4;

type HmacSha256 = Hmac<Sha256>;

/// A secret as the terminal shows it.
#[derive(Clone, Debug)]
pub struct Shown {
    pub secret: [u8; 16],
    pub code: String,
}

impl Shown {
    /// The `crucible://pair` link a QR code carries, which the iPhone's camera opens in Crucible.
    pub fn link(&self, name: &str, hosts: &[String], fingerprint: &str) -> String {
        format!(
            "crucible://pair?v=1&name={}&hosts={}&secret={}&fp={}",
            encode_component(name),
            encode_component(&hosts.join(",")),
            BASE32_NOPAD.encode(&self.secret),
            fingerprint
        )
    }
}

struct Pending {
    secret: [u8; 16],
    id: String,
    expires: Instant,
    exchanges: Vec<(String, String)>,
    failures: u32,
    handed_by: Option<String>,
}

/// Why a pairing step was refused. Every refusal looks the same to the device on purpose.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum Refused {
    #[error("no pairing code is waiting for this device")]
    Unknown,
    #[error("the proof does not match")]
    Proof,
    #[error("that secret is already open or was used")]
    Reused,
    #[error("too many pairings are open")]
    Busy,
}

/// The open secrets the running server holds. A secret the terminal shows reaches it through the database, which
/// keeps it only until it is used or ten minutes pass.
#[derive(Default)]
pub struct Pairings {
    pending: Mutex<Vec<Pending>>,
    spent: Mutex<Vec<(String, Instant)>>,
    store: Option<std::sync::Arc<crate::store::Store>>,
}

/// The id both sides derive from the secret, so a request can name it without revealing it.
pub fn secret_id(secret: &[u8; 16]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"crucible-pair-id");
    hasher.update(secret);
    hex::encode(&hasher.finalize()[..8])
}

fn proof(secret: &[u8; 16], role: &[u8], fingerprint: &str, device_nonce: &str, server_nonce: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC takes a key of any length");
    for part in [role, fingerprint.as_bytes(), device_nonce.as_bytes(), server_nonce.as_bytes()] {
        mac.update(&(part.len() as u32).to_be_bytes());
        mac.update(part);
    }
    hex::encode(mac.finalize().into_bytes())
}

/// What the server sends first: HMAC(secret, "server" ‖ fingerprint ‖ device nonce ‖ server nonce).
pub fn server_proof(secret: &[u8; 16], fingerprint: &str, device_nonce: &str, server_nonce: &str) -> String {
    proof(secret, b"crucible-pair-server", fingerprint, device_nonce, server_nonce)
}

/// What the device answers with once the server's proof checked out.
pub fn device_proof(secret: &[u8; 16], fingerprint: &str, device_nonce: &str, server_nonce: &str) -> String {
    proof(secret, b"crucible-pair-device", fingerprint, device_nonce, server_nonce)
}

/// The secret a typed code spells, ignoring dashes, spaces and case.
pub fn secret_from_code(code: &str) -> Option<[u8; 16]> {
    let cleaned: String = code.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_uppercase()).collect();
    BASE32_NOPAD.decode(cleaned.as_bytes()).ok()?.try_into().ok()
}

fn grouped(secret: &[u8; 16]) -> String {
    let encoded = BASE32_NOPAD.encode(secret);
    encoded.as_bytes().chunks(4).map(|chunk| String::from_utf8_lossy(chunk).into_owned()).collect::<Vec<_>>().join("-")
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buffer);
    hex::encode(buffer)
}

/// A device token: 256 random bits, base32, shown to the device once.
pub fn new_device_token() -> String {
    let mut buffer = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buffer);
    BASE32_NOPAD.encode(&buffer)
}

fn encode_component(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b',' | b':' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

impl Pairings {
    pub fn backed_by(store: std::sync::Arc<crate::store::Store>) -> Self {
        Pairings { pending: Mutex::default(), spent: Mutex::default(), store: Some(store) }
    }

    /// Shows a new secret from a terminal: kept in the database for the running server, returned for the QR code.
    pub fn open_for_server(store: &crate::store::Store) -> rusqlite::Result<Shown> {
        let mut secret = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut secret);
        store.add_pending_pairing(&secret_id(&secret), &secret, crate::store::now() + LIFETIME.as_secs() as i64)?;
        Ok(Shown { secret, code: grouped(&secret) })
    }

    /// Moves a secret the terminal left in the database into memory, if one has this id.
    fn adopt(&self, pending: &mut Vec<Pending>, id: &str) {
        if pending.iter().any(|entry| entry.id == id) {
            return;
        }
        let Some(store) = &self.store else { return };
        if let Ok(Some((secret, expires))) = store.take_pending_pairing(id) {
            let remaining = Duration::from_secs((expires - crate::store::now()).max(0) as u64);
            pending.push(Pending { secret, id: id.to_string(), expires: Instant::now() + remaining, exchanges: Vec::new(), failures: 0, handed_by: None });
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Pending>> {
        self.pending.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn prune(pending: &mut Vec<Pending>, now: Instant) {
        pending.retain(|entry| entry.expires > now && entry.failures < ATTEMPTS);
    }

    /// Opens a new secret for the terminal to show.
    pub fn open(&self) -> Shown {
        let mut secret = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut secret);
        self.insert(secret, None).expect("a fresh random secret is never open or spent")
    }

    /// Opens a secret the paired device `by` brought (an Apple TV's QR code, or one an iPhone made for a nearby Apple
    /// TV). A secret already open, used in the last day, or shown by the terminal is refused, so it pairs one device.
    pub fn open_with(&self, secret: [u8; 16], by: &str) -> Result<Shown, Refused> {
        self.insert(secret, Some(by))
    }

    fn insert(&self, secret: [u8; 16], handed_by: Option<&str>) -> Result<Shown, Refused> {
        let id = secret_id(&secret);
        let now = Instant::now();
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        spent.retain(|(_, at)| at.elapsed() < SPENT_FOR);
        let mut pending = self.lock();
        Self::prune(&mut pending, now);
        let shown_by_terminal = || self.store.as_ref().is_some_and(|store| store.has_pending_pairing(&id).unwrap_or(true));
        if spent.iter().any(|(used, _)| *used == id) || pending.iter().any(|entry| entry.id == id) || handed_by.is_some() && shown_by_terminal() {
            return Err(Refused::Reused);
        }
        if let Some(device) = handed_by {
            let mine: Vec<usize> = pending.iter().enumerate().filter(|(_, entry)| entry.handed_by.as_deref() == Some(device)).map(|(index, _)| index).collect();
            let replaces = mine.len() >= HANDED_PER_DEVICE;
            if pending.len() - usize::from(replaces) >= OPEN_LIMIT {
                return Err(Refused::Busy);
            }
            if replaces {
                pending.remove(mine[0]);
            }
        }
        while pending.len() >= OPEN_LIMIT {
            pending.remove(0);
        }
        pending.push(Pending { secret, id, expires: now + LIFETIME, exchanges: Vec::new(), failures: 0, handed_by: handed_by.map(str::to_string) });
        Ok(Shown { secret, code: grouped(&secret) })
    }

    /// Closes every secret the paired device `device` handed on, once it is unpaired.
    pub fn revoke_handed_by(&self, device: &str) {
        self.lock().retain(|entry| entry.handed_by.as_deref() != Some(device));
    }

    /// Whether the open secret with this id came from a paired device rather than the owner's terminal, so the device
    /// redeeming it must also pass the owner's policy.
    pub fn is_handed(&self, id: &str) -> bool {
        self.lock().iter().any(|entry| entry.id == id && entry.handed_by.is_some())
    }

    /// Step one: the device names the secret and sends its nonce; the server answers with its nonce and its proof.
    pub fn begin(&self, id: &str, device_nonce: &str, fingerprint: &str) -> Result<(String, String), Refused> {
        let spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        if spent.iter().any(|(used, _)| used == id) {
            return Err(Refused::Unknown);
        }
        let mut pending = self.lock();
        Self::prune(&mut pending, Instant::now());
        self.adopt(&mut pending, id);
        let entry = pending.iter_mut().find(|entry| entry.id == id).ok_or(Refused::Unknown)?;
        let server_nonce = random_hex(16);
        let answer = server_proof(&entry.secret, fingerprint, device_nonce, &server_nonce);
        entry.exchanges.push((device_nonce.to_string(), server_nonce.clone()));
        if entry.exchanges.len() > EXCHANGES {
            entry.exchanges.remove(0);
        }
        Ok((server_nonce, answer))
    }

    /// Step two: the device's proof over the same nonces. A match consumes the secret.
    pub fn finish(&self, id: &str, proof: &str, fingerprint: &str) -> Result<(), Refused> {
        let mut spent = self.spent.lock().unwrap_or_else(PoisonError::into_inner);
        let mut pending = self.lock();
        Self::prune(&mut pending, Instant::now());
        let index = pending.iter().position(|entry| entry.id == id).ok_or(Refused::Unknown)?;
        let entry = &mut pending[index];
        if entry.exchanges.is_empty() {
            return Err(Refused::Unknown);
        }
        let matched = entry.exchanges.iter().any(|(device_nonce, server_nonce)| {
            constant_time_equal(device_proof(&entry.secret, fingerprint, device_nonce, server_nonce).as_bytes(), proof.as_bytes())
        });
        if !matched {
            entry.failures += 1;
            return Err(Refused::Proof);
        }
        pending.remove(index);
        if spent.len() >= SPENT_LIMIT {
            spent.remove(0);
        }
        spent.push((id.to_string(), Instant::now()));
        Ok(())
    }
}

fn constant_time_equal(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    const FP: &str = "ab12";

    #[test]
    fn a_device_that_saw_the_secret_pairs_once() {
        let pairings = Pairings::default();
        let shown = pairings.open();
        let id = secret_id(&shown.secret);
        let (server_nonce, server_said) = pairings.begin(&id, "dn", FP).unwrap();
        assert_eq!(server_said, server_proof(&shown.secret, FP, "dn", &server_nonce));
        pairings.finish(&id, &device_proof(&shown.secret, FP, "dn", &server_nonce), FP).unwrap();
        assert_eq!(pairings.begin(&id, "dn", FP), Err(Refused::Unknown));
    }

    #[test]
    fn a_different_certificate_breaks_the_proof() {
        let pairings = Pairings::default();
        let shown = pairings.open();
        let id = secret_id(&shown.secret);
        let (server_nonce, server_said) = pairings.begin(&id, "dn", "impostor").unwrap();
        assert_ne!(server_said, server_proof(&shown.secret, FP, "dn", &server_nonce));
        assert_eq!(pairings.finish(&id, &device_proof(&shown.secret, FP, "dn", &server_nonce), "impostor"), Err(Refused::Proof));
    }

    #[test]
    fn wrong_proofs_burn_the_secret() {
        let pairings = Pairings::default();
        let shown = pairings.open();
        let id = secret_id(&shown.secret);
        pairings.begin(&id, "dn", FP).unwrap();
        for _ in 0..ATTEMPTS {
            assert_eq!(pairings.finish(&id, "00", FP), Err(Refused::Proof));
        }
        assert_eq!(pairings.begin(&id, "dn", FP), Err(Refused::Unknown));
    }

    #[test]
    fn a_secret_shown_by_the_terminal_reaches_the_server_through_the_database() {
        let store = std::sync::Arc::new(crate::store::Store::in_memory().unwrap());
        let shown = Pairings::open_for_server(&store).unwrap();
        let server = Pairings::backed_by(store);
        let id = secret_id(&shown.secret);
        let (server_nonce, _) = server.begin(&id, "dn", FP).unwrap();
        server.finish(&id, &device_proof(&shown.secret, FP, "dn", &server_nonce), FP).unwrap();
    }

    #[test]
    fn proofs_match_the_vectors_the_app_checks() {
        let secret = [1u8; 16];
        assert_eq!(server_proof(&secret, "ab12", "dn", "sn"), "52332ef92a0c052dc12c4aa512604632136ebd2dd837fe4d0a3eb56c0b788336");
        assert_eq!(device_proof(&secret, "ab12", "dn", "sn"), "476d5e66beda9d7f2bd25fb30fc206e259411d14a04e81b7054535544d1e51c1");
        assert_eq!(secret_id(&secret), "31d9e8154cbc91a2");
        assert_eq!(BASE32_NOPAD.encode(&secret), "AEAQCAIBAEAQCAIBAEAQCAIBAE");
    }

    #[test]
    fn a_handed_secret_pairs_one_device_and_cannot_be_handed_again() {
        let pairings = Pairings::default();
        let secret = [9u8; 16];
        pairings.open_with(secret, "phone").unwrap();
        assert_eq!(pairings.open_with(secret, "phone").err(), Some(Refused::Reused));
        let id = secret_id(&secret);
        assert!(pairings.is_handed(&id));
        let (server_nonce, _) = pairings.begin(&id, "dn", FP).unwrap();
        pairings.finish(&id, &device_proof(&secret, FP, "dn", &server_nonce), FP).unwrap();
        assert_eq!(pairings.open_with(secret, "other").err(), Some(Refused::Reused));
        assert_eq!(pairings.begin(&id, "dn", FP), Err(Refused::Unknown));
        assert!(!pairings.is_handed(&secret_id(&pairings.open().secret)));
    }

    #[test]
    fn a_secret_the_terminal_shows_cannot_be_handed_on() {
        let store = std::sync::Arc::new(crate::store::Store::in_memory().unwrap());
        let shown = Pairings::open_for_server(&store).unwrap();
        let server = Pairings::backed_by(store);
        assert_eq!(server.open_with(shown.secret, "phone").err(), Some(Refused::Reused));
        let id = secret_id(&shown.secret);
        assert!(!server.is_handed(&id));
        let (server_nonce, _) = server.begin(&id, "dn", FP).unwrap();
        server.finish(&id, &device_proof(&shown.secret, FP, "dn", &server_nonce), FP).unwrap();
        assert_eq!(server.begin(&id, "dn", FP), Err(Refused::Unknown));
    }

    #[test]
    fn a_later_exchange_does_not_spoil_an_earlier_one() {
        let pairings = Pairings::default();
        let secret = [5u8; 16];
        pairings.open_with(secret, "phone").unwrap();
        let id = secret_id(&secret);
        let (first, _) = pairings.begin(&id, "television", FP).unwrap();
        pairings.begin(&id, "onlooker", FP).unwrap();
        pairings.finish(&id, &device_proof(&secret, FP, "television", &first), FP).unwrap();
    }

    #[test]
    fn unpairing_a_device_closes_what_it_handed_on() {
        let pairings = Pairings::default();
        pairings.open_with([6u8; 16], "phone").unwrap();
        pairings.open_with([7u8; 16], "tablet").unwrap();
        pairings.revoke_handed_by("phone");
        assert!(!pairings.is_handed(&secret_id(&[6u8; 16])));
        assert!(pairings.is_handed(&secret_id(&[7u8; 16])));
    }

    #[test]
    fn an_expired_terminal_secret_cannot_be_handed_on_either() {
        let store = std::sync::Arc::new(crate::store::Store::in_memory().unwrap());
        let secret = [8u8; 16];
        store.add_pending_pairing(&secret_id(&secret), &secret, crate::store::now() - 1).unwrap();
        let server = Pairings::backed_by(store);
        assert_eq!(server.open_with(secret, "phone").err(), Some(Refused::Reused));
    }

    #[test]
    fn one_device_cannot_crowd_out_the_others() {
        let pairings = Pairings::default();
        let theirs = [1u8; 16];
        pairings.open_with(theirs, "phone").unwrap();
        for byte in 2..20u8 {
            pairings.open_with([byte; 16], "flooder").unwrap();
        }
        assert!(pairings.is_handed(&secret_id(&theirs)));
        assert!(!pairings.is_handed(&secret_id(&[2u8; 16])));
        assert!(pairings.is_handed(&secret_id(&[19u8; 16])));
        for (index, device) in ["a", "b"].iter().enumerate() {
            pairings.open_with([100 + index as u8; 16], device).unwrap();
            pairings.open_with([110 + index as u8; 16], device).unwrap();
        }
        pairings.open_with([120u8; 16], "c").unwrap();
        assert_eq!(pairings.open_with([121u8; 16], "d").err(), Some(Refused::Busy));
        pairings.open_with([122u8; 16], "a").unwrap();
        assert!(!pairings.is_handed(&secret_id(&[100u8; 16])));
        assert!(pairings.is_handed(&secret_id(&[110u8; 16])));
        assert!(pairings.is_handed(&secret_id(&theirs)));
    }

    #[test]
    fn the_typed_code_spells_the_secret() {
        let pairings = Pairings::default();
        let shown = pairings.open();
        assert_eq!(secret_from_code(&shown.code.to_lowercase()), Some(shown.secret));
        assert!(shown.code.contains('-'));
    }

    #[test]
    fn the_link_carries_hosts_secret_and_fingerprint() {
        let shown = Shown { secret: [1; 16], code: String::new() };
        let link = shown.link("arch box", &["192.168.1.5:32500".into(), "100.64.0.2:32500".into()], "ff00");
        assert!(link.starts_with("crucible://pair?v=1&name=arch%20box&hosts=192.168.1.5:32500,100.64.0.2:32500&secret="));
        assert!(link.ends_with("&fp=ff00"));
    }
}
