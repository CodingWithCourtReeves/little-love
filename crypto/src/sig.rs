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

/// Domain-separation tag for `ConsumeInvite`. See spec §4.1 step 10 + §8.5.1.
/// The signed input is `INVITE_CONSUME_DOMAIN_TAG || 0x00 || canonical_token`
/// (30 ASCII bytes + 1 NUL delimiter + 32 canonical token bytes = 63 bytes).
pub const INVITE_CONSUME_DOMAIN_TAG: &[u8] = b"littlelove.v0.2.invite-consume";

/// Domain-separation tag for `POST /accounts/bot` (spec v0.3 §4.1 + §8.3).
/// Signed input: `BOT_REGISTER_DOMAIN_TAG || 0x00 || bot_ed25519_pub || bot_x25519_pub`
/// (28 ASCII bytes + 1 NUL delimiter + 32 + 32 pubkey bytes = 93 bytes).
/// Binding BOTH pubkeys prevents an attacker who intercepts the registration
/// request from substituting their own x25519 key for end-to-end attacks.
pub const BOT_REGISTER_DOMAIN_TAG: &[u8] = b"littlelove.v0.3.bot-register";

/// Domain-separation tag for `DELETE /accounts/bot/{label}` (spec v0.3 §4.x).
/// Signed input: `BOT_DELETE_DOMAIN_TAG || 0x00 || label_utf8 || 0x00 || nonce`.
/// Binding the server-issued challenge nonce makes captured signatures
/// single-use (replay resistance).
pub const BOT_DELETE_DOMAIN_TAG: &[u8] = b"littlelove.v0.3.bot-delete";

fn signing_input(tag: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(tag.len() + 1 + payload.len());
    out.extend_from_slice(tag);
    out.push(0u8);
    out.extend_from_slice(payload);
    out
}

/// Build the domain-separated signing input for a Challenge nonce.
/// Used by both the verifier (this module) and by tests that sign on the client side.
pub fn challenge_signing_input(nonce: &[u8]) -> Vec<u8> {
    signing_input(CHALLENGE_DOMAIN_TAG, nonce)
}

/// Build the domain-separated signing input for an invite-consume token.
/// Mirrors `challenge_signing_input` but uses the invite-consume tag (spec §8.5.1).
pub fn invite_consume_signing_input(token: &[u8]) -> Vec<u8> {
    signing_input(INVITE_CONSUME_DOMAIN_TAG, token)
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

fn verify_domain_separated(
    pub_key: &[u8],
    input: &[u8],
    signature: &[u8],
) -> Result<(), AuthError> {
    let key_arr: [u8; 32] = pub_key
        .try_into()
        .map_err(|_| AuthError::BadPubkey(pub_key.len()))?;
    let sig_arr: [u8; 64] = signature
        .try_into()
        .map_err(|_| AuthError::BadSignature(signature.len()))?;
    let vk = VerifyingKey::from_bytes(&key_arr).map_err(|_| AuthError::BadPubkey(32))?;
    let sig = Signature::from_bytes(&sig_arr);
    // verify_strict (not verify): rejects weak public keys and signature
    // malleability from curve25519's cofactor of 8. The dalek docs explicitly
    // warn that plain verify is "dangerous in identification protocols" —
    // exactly the use case here. See ed25519-dalek VerifyingKey docs.
    vk.verify_strict(input, &sig)
        .map_err(|_| AuthError::Mismatch)
}

/// Verify that `signature` is a valid Ed25519 sig over the domain-separated
/// input derived from `nonce` (see `challenge_signing_input` + spec §8.5.1).
/// The function takes the raw 32-byte nonce; it builds the prefixed input
/// internally so callers cannot accidentally skip the tag.
pub fn verify_signature(pub_key: &[u8], nonce: &[u8], signature: &[u8]) -> Result<(), AuthError> {
    verify_domain_separated(pub_key, &challenge_signing_input(nonce), signature)
}

/// Verify a `ConsumeInvite` signature. Same shape as `verify_signature` but
/// uses the `littlelove.v0.2.invite-consume` domain tag (spec §8.5.1).
/// `token` is the canonical 32-byte invite token (see `crate::invites`).
pub fn verify_invite_consume_signature(
    pub_key: &[u8],
    token: &[u8],
    signature: &[u8],
) -> Result<(), AuthError> {
    verify_domain_separated(pub_key, &invite_consume_signing_input(token), signature)
}

/// Build the domain-separated signing input for `POST /accounts/bot`.
/// Binds both of the bot's pubkeys so the owner's signature authorises a
/// *specific* identity (preventing x25519 key substitution by an attacker
/// who can intercept the registration request).
pub fn bot_register_signing_input(bot_ed25519_pub: &[u8], bot_x25519_pub: &[u8]) -> Vec<u8> {
    let mut combined = Vec::with_capacity(bot_ed25519_pub.len() + bot_x25519_pub.len());
    combined.extend_from_slice(bot_ed25519_pub);
    combined.extend_from_slice(bot_x25519_pub);
    signing_input(BOT_REGISTER_DOMAIN_TAG, &combined)
}

/// Build the domain-separated signing input for `DELETE /accounts/bot/{label}`.
/// The signed payload is `label || 0x00 || nonce`; the outer `signing_input`
/// helper then prepends `BOT_DELETE_DOMAIN_TAG || 0x00`. The nonce is the
/// server-issued challenge value from `POST /accounts/bot/{label}/delete-challenge`.
pub fn bot_delete_signing_input(label: &[u8], nonce: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(label.len() + 1 + nonce.len());
    payload.extend_from_slice(label);
    payload.push(0u8);
    payload.extend_from_slice(nonce);
    signing_input(BOT_DELETE_DOMAIN_TAG, &payload)
}

/// Verify an owner's signature authorising a bot registration.
pub fn verify_bot_register_signature(
    owner_pub: &[u8],
    bot_ed25519_pub: &[u8],
    bot_x25519_pub: &[u8],
    signature: &[u8],
) -> Result<(), AuthError> {
    verify_domain_separated(
        owner_pub,
        &bot_register_signing_input(bot_ed25519_pub, bot_x25519_pub),
        signature,
    )
}

/// Verify an owner's signature authorising a bot deletion. The signature
/// must cover both `label` AND the server-issued challenge `nonce`.
pub fn verify_bot_delete_signature(
    owner_pub: &[u8],
    label: &[u8],
    nonce: &[u8],
    signature: &[u8],
) -> Result<(), AuthError> {
    verify_domain_separated(
        owner_pub,
        &bot_delete_signing_input(label, nonce),
        signature,
    )
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
    fn invite_consume_signing_input_has_expected_layout() {
        let token = [0u8; 32];
        let input = invite_consume_signing_input(&token);
        // 30 ASCII bytes (tag) + 1 NUL + 32 token bytes = 63.
        assert_eq!(input.len(), 63);
        assert_eq!(&input[..30], INVITE_CONSUME_DOMAIN_TAG);
        assert_eq!(input[30], 0u8);
        assert_eq!(&input[31..], &token[..]);
    }

    #[test]
    fn verify_invite_consume_accepts_valid_sig() {
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let token = [0x42u8; 32];
        let sig = sk.sign(&invite_consume_signing_input(&token)).to_bytes();
        assert!(verify_invite_consume_signature(&pk, &token, &sig).is_ok());
    }

    #[test]
    fn verify_invite_consume_rejects_bare_token_signature() {
        // §8.5.1 regression: signing the raw token bytes (no tag) must fail.
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let token = [0x42u8; 32];
        let bare_sig = sk.sign(&token).to_bytes();
        assert_eq!(
            verify_invite_consume_signature(&pk, &token, &bare_sig),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn verify_invite_consume_rejects_cross_context_signature() {
        // §8.5.1 rationale: a Challenge-tagged signature must not interop
        // with the invite-consume verifier, even if the underlying payload
        // bytes were arranged to coincide.
        let sk = SigningKey::generate(&mut OsRng);
        let pk = sk.verifying_key().to_bytes();
        let token = [0x42u8; 32];
        // Sign with the *Challenge* domain over the same bytes:
        let wrong_domain_sig = sk.sign(&challenge_signing_input(&token)).to_bytes();
        assert_eq!(
            verify_invite_consume_signature(&pk, &token, &wrong_domain_sig),
            Err(AuthError::Mismatch)
        );
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

    #[test]
    fn bot_register_signing_input_has_expected_layout() {
        let ed = [0xAAu8; 32];
        let x = [0xBBu8; 32];
        let input = bot_register_signing_input(&ed, &x);
        // 28 ASCII bytes (tag) + 1 NUL + 32 + 32 pubkey bytes = 93.
        assert_eq!(input.len(), 93);
        assert_eq!(&input[..28], BOT_REGISTER_DOMAIN_TAG);
        assert_eq!(input[28], 0u8);
        assert_eq!(&input[29..61], &ed[..]);
        assert_eq!(&input[61..], &x[..]);
    }

    #[test]
    fn bot_delete_signing_input_has_expected_layout() {
        let label = b"garden";
        let nonce = [0xAAu8; 32];
        let input = bot_delete_signing_input(label, &nonce);
        // 26 (tag) + 1 NUL + 6 (label) + 1 NUL + 32 (nonce) = 66.
        assert_eq!(input.len(), 26 + 1 + label.len() + 1 + nonce.len());
        assert_eq!(&input[..26], BOT_DELETE_DOMAIN_TAG);
        assert_eq!(input[26], 0u8);
        assert_eq!(&input[27..33], &label[..]);
        assert_eq!(input[33], 0u8);
        assert_eq!(&input[34..], &nonce[..]);
    }

    #[test]
    fn verify_bot_register_accepts_valid_sig() {
        let owner = SigningKey::generate(&mut OsRng);
        let bot_ed = [0x42u8; 32];
        let bot_x = [0x43u8; 32];
        let sig = owner
            .sign(&bot_register_signing_input(&bot_ed, &bot_x))
            .to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert!(verify_bot_register_signature(&owner_pk, &bot_ed, &bot_x, &sig).is_ok());
    }

    #[test]
    fn verify_bot_register_rejects_cross_domain_sig() {
        // Signing with the Challenge tag over the same payload must fail —
        // domain separation enforces context (spec §8.5.1).
        let owner = SigningKey::generate(&mut OsRng);
        let bot_ed = [0x42u8; 32];
        let bot_x = [0x43u8; 32];
        let cross = owner.sign(&challenge_signing_input(&bot_ed)).to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert_eq!(
            verify_bot_register_signature(&owner_pk, &bot_ed, &bot_x, &cross),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn verify_bot_register_rejects_x25519_substitution() {
        // An attacker who reuses the owner's signature with a different
        // x25519_pub must be rejected — both keys are bound.
        let owner = SigningKey::generate(&mut OsRng);
        let bot_ed = [0x42u8; 32];
        let real_x = [0x43u8; 32];
        let attacker_x = [0x99u8; 32];
        let sig = owner
            .sign(&bot_register_signing_input(&bot_ed, &real_x))
            .to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert_eq!(
            verify_bot_register_signature(&owner_pk, &bot_ed, &attacker_x, &sig),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn verify_bot_delete_accepts_valid_sig() {
        let owner = SigningKey::generate(&mut OsRng);
        let label = b"journal";
        let nonce = random_nonce();
        let sig = owner
            .sign(&bot_delete_signing_input(label, &nonce))
            .to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert!(verify_bot_delete_signature(&owner_pk, label, &nonce, &sig).is_ok());
    }

    #[test]
    fn verify_bot_delete_rejects_wrong_label() {
        let owner = SigningKey::generate(&mut OsRng);
        let nonce = random_nonce();
        let sig = owner
            .sign(&bot_delete_signing_input(b"garden", &nonce))
            .to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert_eq!(
            verify_bot_delete_signature(&owner_pk, b"journal", &nonce, &sig),
            Err(AuthError::Mismatch)
        );
    }

    #[test]
    fn verify_bot_delete_rejects_nonce_substitution() {
        // The defining property of the new scheme: a signature valid for
        // one nonce must fail under any other nonce.
        let owner = SigningKey::generate(&mut OsRng);
        let label = b"journal";
        let nonce_a = random_nonce();
        let nonce_b = random_nonce();
        let sig = owner
            .sign(&bot_delete_signing_input(label, &nonce_a))
            .to_bytes();
        let owner_pk = owner.verifying_key().to_bytes();
        assert_eq!(
            verify_bot_delete_signature(&owner_pk, label, &nonce_b, &sig),
            Err(AuthError::Mismatch)
        );
    }
}
