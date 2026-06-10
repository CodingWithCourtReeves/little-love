//! BIP39 phrase → master → Ed25519 + X25519 keypairs (spec §3.1).
//!
//! 256-bit seeds only (12-word phrases ARE allowed by BIP39 but only with
//! 128-bit entropy + checksum — see §3.1 step 2: this protocol generates a
//! 256-bit OS-CSPRNG seed). For v0.2 we therefore emit a 24-word phrase.

use ed25519_dalek::SigningKey as EdSigningKey;
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use thiserror::Error;
use x25519_dalek::StaticSecret;

use crate::wordlist::BIP39_EN;

pub const SEED_LEN: usize = 32;
const SALT_MASTER: &[u8] = b"littlelove.v0.2.master";
const SALT_SIGNING: &[u8] = b"littlelove.v0.2.signing";
const SALT_ENCRYPTION: &[u8] = b"littlelove.v0.2.encryption";

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("phrase must be exactly 24 words, got {0}")]
    WrongWordCount(usize),
    #[error("unknown BIP39 word: {0}")]
    UnknownWord(String),
    #[error("HKDF expand failed")]
    Hkdf,
}

#[derive(Clone)]
pub struct Identity {
    pub master: [u8; 32],
    pub ed25519_signing: EdSigningKey,
    pub x25519_secret: StaticSecret,
}

impl Identity {
    pub fn ed25519_pub(&self) -> [u8; 32] {
        self.ed25519_signing.verifying_key().to_bytes()
    }
    pub fn x25519_pub(&self) -> [u8; 32] {
        use x25519_dalek::PublicKey;
        PublicKey::from(&self.x25519_secret).to_bytes()
    }
}

/// Generate a fresh 256-bit seed.
pub fn random_seed() -> [u8; SEED_LEN] {
    let mut s = [0u8; SEED_LEN];
    rand::rngs::OsRng.fill_bytes(&mut s);
    s
}

/// 256 bits of entropy → 24 BIP39 words (no checksum; the seed IS canonical).
///
/// BIP39 normally adds a checksum; we follow the spec §3.1 simplification:
/// the seed is the canonical thing, and the words are a human carrier.
/// Encoding: 24 11-bit indices, big-endian, with 8 trailing bits set to
/// zero (256 + 8 = 264 = 24 * 11). Decoding strips those zero bits.
pub fn seed_to_phrase(seed: &[u8; SEED_LEN]) -> String {
    let mut bits = [0u8; 33]; // 264 bits
    bits[..32].copy_from_slice(seed);
    let mut words = Vec::with_capacity(24);
    for i in 0..24 {
        let start = i * 11;
        let end = start + 11;
        let mut v = 0u16;
        for b in start..end {
            let byte = bits[b / 8];
            let bit = (byte >> (7 - (b % 8))) & 1;
            v = (v << 1) | bit as u16;
        }
        words.push(BIP39_EN[v as usize]);
    }
    words.join(" ")
}

pub fn phrase_to_seed(phrase: &str) -> Result<[u8; SEED_LEN], IdentityError> {
    let words: Vec<&str> = phrase.split_whitespace().collect();
    if words.len() != 24 {
        return Err(IdentityError::WrongWordCount(words.len()));
    }
    let lookup: std::collections::HashMap<&str, u16> = BIP39_EN
        .iter()
        .enumerate()
        .map(|(i, w)| (*w, i as u16))
        .collect();
    let mut bits = [0u8; 33];
    for (i, w) in words.iter().enumerate() {
        let idx = *lookup
            .get(w)
            .ok_or_else(|| IdentityError::UnknownWord((*w).to_string()))?;
        for j in 0..11 {
            let global = i * 11 + j;
            let bit = (idx >> (10 - j)) & 1;
            bits[global / 8] |= (bit as u8) << (7 - (global % 8));
        }
    }
    let mut seed = [0u8; SEED_LEN];
    seed.copy_from_slice(&bits[..32]);
    Ok(seed)
}

pub fn derive_identity(seed: &[u8; SEED_LEN]) -> Result<Identity, IdentityError> {
    let master = hkdf_extract_expand(SALT_MASTER, seed, &[])?;
    let signing_seed = hkdf_extract_expand(SALT_SIGNING, &master, &[])?;
    let enc_seed = hkdf_extract_expand(SALT_ENCRYPTION, &master, &[])?;
    Ok(Identity {
        master,
        ed25519_signing: EdSigningKey::from_bytes(&signing_seed),
        x25519_secret: StaticSecret::from(enc_seed),
    })
}

fn hkdf_extract_expand(salt: &[u8], ikm: &[u8], info: &[u8]) -> Result<[u8; 32], IdentityError> {
    let hk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).map_err(|_| IdentityError::Hkdf)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phrase_round_trip() {
        let seed = random_seed();
        let phrase = seed_to_phrase(&seed);
        let back = phrase_to_seed(&phrase).unwrap();
        assert_eq!(seed, back);
    }

    #[test]
    fn same_seed_derives_same_identity() {
        let seed = [0x33u8; 32];
        let a = derive_identity(&seed).unwrap();
        let b = derive_identity(&seed).unwrap();
        assert_eq!(a.master, b.master);
        assert_eq!(a.ed25519_pub(), b.ed25519_pub());
        assert_eq!(a.x25519_pub(), b.x25519_pub());
    }

    #[test]
    fn different_seeds_diverge() {
        let a = derive_identity(&[0u8; 32]).unwrap();
        let b = derive_identity(&[1u8; 32]).unwrap();
        assert_ne!(a.ed25519_pub(), b.ed25519_pub());
        assert_ne!(a.x25519_pub(), b.x25519_pub());
    }

    #[test]
    fn phrase_rejects_unknown_word() {
        let bogus = (0..24).map(|_| "bogusword").collect::<Vec<_>>().join(" ");
        let err = phrase_to_seed(&bogus).unwrap_err();
        assert!(matches!(err, IdentityError::UnknownWord(_)));
    }
}
