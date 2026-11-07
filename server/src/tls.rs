//! The server's own certificate, made at setup. Devices never trust it through a CA: they pin its SHA-256
//! fingerprint, learned only through a pairing that proves both sides saw the same secret.

use std::fs;
use std::io;

use sha2::{Digest, Sha256};

use crate::paths::{write_private, Paths};

/// The certificate in PEM and its fingerprint, as devices pin it.
#[derive(Clone, Debug)]
pub struct Identity {
    pub certificate_pem: String,
    pub fingerprint: String,
}

/// Loads the certificate made at setup, or makes one when there is none.
pub fn load_or_create(paths: &Paths, name: &str) -> io::Result<Identity> {
    if !paths.certificate().exists() || !paths.private_key().exists() {
        create(paths, name)?;
    }
    let certificate_pem = fs::read_to_string(paths.certificate())?;
    let fingerprint = fingerprint_of_pem(&certificate_pem)?;
    Ok(Identity { certificate_pem, fingerprint })
}

/// Replaces the certificate, which unpairs every device: the only way the fingerprint ever changes.
pub fn create(paths: &Paths, name: &str) -> io::Result<()> {
    let names = vec![name.to_string(), "localhost".to_string(), format!("{name}.local")];
    let made = rcgen::generate_simple_self_signed(names).map_err(io::Error::other)?;
    write_private(&paths.private_key(), made.key_pair.serialize_pem().as_bytes())?;
    write_private(&paths.certificate(), made.cert.pem().as_bytes())
}

/// The SHA-256 of the certificate's DER bytes, lowercase hex: what a device sees on the TLS connection it is on.
pub fn fingerprint_of_pem(pem: &str) -> io::Result<String> {
    let der = der_of_pem(pem).ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "certificate.pem holds no certificate"))?;
    Ok(hex::encode(Sha256::digest(der)))
}

fn der_of_pem(pem: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let body: String = pem
        .lines()
        .skip_while(|line| !line.starts_with("-----BEGIN CERTIFICATE-----"))
        .skip(1)
        .take_while(|line| !line.starts_with("-----END CERTIFICATE-----"))
        .collect();
    base64::engine::general_purpose::STANDARD.decode(body).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn makes_a_certificate_once_and_keeps_its_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::at(dir.path());
        let first = load_or_create(&paths, "arch").unwrap();
        let again = load_or_create(&paths, "arch").unwrap();
        assert_eq!(first.fingerprint, again.fingerprint);
        assert_eq!(first.fingerprint.len(), 64);
        create(&paths, "arch").unwrap();
        assert_ne!(load_or_create(&paths, "arch").unwrap().fingerprint, first.fingerprint);
    }
}
