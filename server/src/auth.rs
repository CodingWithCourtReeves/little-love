//! WSS auth surface: nonce generation + Ed25519 signature verification.
//!
//! Spec: docs/superpowers/specs/2026-06-09-littlelove-accounts-and-inbox-design.md §3.3, §8.2, §8.5.1.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use rand::RngCore;
use thiserror::Error;

/// Length of a Challenge nonce in bytes (spec §8.2).
pub const NONCE_LEN: usize = 32;

/// Domain-separation tag for the WSS Challenge response signing input.
/// See spec §8.5.1. The signed input is `CHALLENGE_DOMAIN_TAG || 0x00 || nonce`
/// (25 ASCII bytes + 1 NUL delimiter + 32 nonce bytes = 58 bytes).
pub const CHALLENGE_DOMAIN_TAG: &[u8] = b"littlelove.v0.2.challenge";

/// Build the domain-separated signing input for a Challenge nonce.
/// Used by both the verifier (this module) and by tests that sign on the client side.
pub fn challenge_signing_input(nonce: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(CHALLENGE_DOMAIN_TAG.len() + 1 + nonce.len());
    out.extend_from_slice(CHALLENGE_DOMAIN_TAG);
    out.push(0u8);
    out.extend_from_slice(nonce);
    out
}

/// Generate a 32-byte cryptographically-random nonce.
///
/// Spec §3.3: the server's first frame after WSS upgrade is `Challenge { nonce }`.
pub fn random_nonce() -> [u8; NONCE_LEN] {
    let mut buf = [0u8; NONCE_LEN];
    rand::rngs::OsRng.fill_bytes(&mut buf);
    buf
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AuthError {
    #[error("public key has wrong length: {0}")]
    BadPubkey(usize),
    #[error("signature has wrong length: {0}")]
    BadSignature(usize),
    #[error("invalid base64")]
    InvalidBase64,
    #[error("signature did not verify")]
    Mismatch,
}

/// Decode base64 → bytes.
pub fn decode_b64(s: &str) -> Result<Vec<u8>, AuthError> {
    B64.decode(s).map_err(|_| AuthError::InvalidBase64)
}

/// Encode bytes → base64.
pub fn encode_b64(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

/// Verify that `signature` is a valid Ed25519 sig over the domain-separated
/// input derived from `nonce` (see `challenge_signing_input` + spec §8.5.1).
/// The function takes the raw 32-byte nonce; it builds the prefixed input
/// internally so callers cannot accidentally skip the tag.
pub fn verify_signature(pub_key: &[u8], nonce: &[u8], signature: &[u8]) -> Result<(), AuthError> {
    let key_arr: [u8; 32] = pub_key
        .try_into()
        .map_err(|_| AuthError::BadPubkey(pub_key.len()))?;
    let sig_arr: [u8; 64] = signature
        .try_into()
        .map_err(|_| AuthError::BadSignature(signature.len()))?;
    let vk = VerifyingKey::from_bytes(&key_arr).map_err(|_| AuthError::BadPubkey(32))?;
    let sig = Signature::from_bytes(&sig_arr);
    let input = challenge_signing_input(nonce);
    // verify_strict (not verify): rejects weak public keys and signature
    // malleability from curve25519's cofactor of 8. The dalek docs explicitly
    // warn that plain verify is "dangerous in identification protocols" —
    // exactly the use case here. See ed25519-dalek VerifyingKey docs.
    vk.verify_strict(&input, &sig)
        .map_err(|_| AuthError::Mismatch)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use rand::rngs::OsRng;
    use std::collections::HashSet;

    #[test]
    fn random_nonce_returns_32_bytes() {
        let n = random_nonce();
        assert_eq!(n.len(), 32);
    }

    #[test]
    fn random_nonce_never_repeats_across_10000_calls() {
        let mut seen = HashSet::new();
        for _ in 0..10_000 {
            assert!(seen.insert(random_nonce()), "nonce collision");
        }
    }

    #[test]
    fn verify_signature_accepts_valid_sig() {
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let nonce = random_nonce();
        // Signer must build the same domain-separated input the verifier uses.
        let sig = sk.sign(&challenge_signing_input(&nonce)).to_bytes();
        assert!(verify_signature(&pk, &nonce, &sig).is_ok());
    }

    #[test]
    fn verify_signature_rejects_tampered_nonce() {
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let nonce = random_nonce();
        let sig = sk.sign(&challenge_signing_input(&nonce)).to_bytes();
        let mut bad = nonce;
        bad[0] ^= 0x01;
        assert_eq!(verify_signature(&pk, &bad, &sig), Err(AuthError::Mismatch));
    }

    #[test]
    fn verify_signature_rejects_wrong_key() {
        let sk = SigningKey::generate(&mut OsRng);
        let other = SigningKey::generate(&mut OsRng);
        let nonce = random_nonce();
        let sig = sk.sign(&challenge_signing_input(&nonce)).to_bytes();
        let other_pk = other.verifying_key().to_bytes();
        assert_eq!(
            verify_signature(&other_pk, &nonce, &sig),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn verify_signature_rejects_bare_nonce_signature() {
        // Spec §8.5.1 regression test: a client that signs the raw nonce
        // (without the domain-separation tag) must be rejected.
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let nonce = random_nonce();
        let bare_sig = sk.sign(&nonce).to_bytes();
        assert_eq!(
            verify_signature(&pk, &nonce, &bare_sig),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn challenge_signing_input_has_expected_layout() {
        let nonce = [0u8; 32];
        let input = challenge_signing_input(&nonce);
        assert_eq!(input.len(), 58);
        assert_eq!(&input[..25], CHALLENGE_DOMAIN_TAG);
        assert_eq!(input[25], 0u8);
        assert_eq!(&input[26..], &nonce[..]);
    }

    #[test]
    fn verify_signature_rejects_wrong_pubkey_length() {
        let sig = [0u8; 64];
        let nonce = [0u8; 32];
        let pk = [0u8; 31];
        assert_eq!(
            verify_signature(&pk, &nonce, &sig),
            Err(AuthError::BadPubkey(31))
        );
    }

    #[test]
    fn verify_signature_rejects_wrong_sig_length() {
        let pk = [0u8; 32];
        let nonce = [0u8; 32];
        let sig = [0u8; 63];
        assert_eq!(
            verify_signature(&pk, &nonce, &sig),
            Err(AuthError::BadSignature(63))
        );
    }

    #[test]
    fn b64_round_trip() {
        let bytes = [0u8, 1, 2, 254, 255];
        let s = encode_b64(&bytes);
        assert_eq!(decode_b64(&s).unwrap(), bytes);
    }
}
