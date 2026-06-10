//! Invites: BIP39-encoded 4-word codes + DB persistence + REST preview.
//!
//! Spec: §4 (Pairing & Invites), §8.1 (`POST /invites/{code}/preview`),
//! §8.2 (CreateInvite/ConsumeInvite/InviteCreated/InviteConsumed frames),
//! §8.6 (BIP39 invite encoding).

use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};
use rand::RngCore;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use thiserror::Error;

use littlelove_crypto::wordlist::BIP39_EN;

/// Invites expire 1 hour after creation per spec §4.2.
pub const INVITE_TTL_SECONDS: i64 = 60 * 60;

/// Number of words in an invite code (spec §8.6).
pub const CODE_WORDS: usize = 4;

/// Bits each BIP39 word encodes.
const BITS_PER_WORD: u32 = 11;

/// Total information bits in an invite code: 4 × 11 = 44 bits.
const CODE_BITS: u32 = CODE_WORDS as u32 * BITS_PER_WORD;

/// Number of bytes a code occupies in canonical form. The canonical 32-byte
/// invite token (used for SHA-256 hashing and signature payloads) is:
///
///   bytes[0..6]   = n44 << 4  (big-endian)   — the code's 44 bits in the
///                                              top 44 bits of bytes 0..6
///   bytes[6..32]  = 0x00                     — fixed zero padding
///
/// 44 bits of entropy is accepted because invites are single-use with a
/// 1-hour expiry and server-side rate limits (spec §4.2 + §8.6.3).
pub const CANONICAL_TOKEN_LEN: usize = 32;

/// Length of the prefix that actually carries the code's entropy.
const TOKEN_PREFIX_LEN: usize = 6;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum InviteCodeError {
    #[error("invite code must have exactly {expected} words, got {got}")]
    WrongWordCount { expected: usize, got: usize },
    #[error("unknown BIP39 word: {0:?}")]
    UnknownWord(String),
}

/// Build the canonical 32-byte invite token from a 44-bit code value.
/// Public for callers that want to sign over or hash the canonical bytes
/// without first round-tripping through the string code.
pub fn canonical_token_from_n44(n44: u64) -> [u8; CANONICAL_TOKEN_LEN] {
    debug_assert_eq!(n44 >> CODE_BITS, 0, "n44 must fit in 44 bits");
    let prefix_u64 = n44 << 4; // shift into top 44 bits of a 48-bit slot
    let mut out = [0u8; CANONICAL_TOKEN_LEN];
    out[0] = ((prefix_u64 >> 40) & 0xFF) as u8;
    out[1] = ((prefix_u64 >> 32) & 0xFF) as u8;
    out[2] = ((prefix_u64 >> 24) & 0xFF) as u8;
    out[3] = ((prefix_u64 >> 16) & 0xFF) as u8;
    out[4] = ((prefix_u64 >> 8) & 0xFF) as u8;
    out[5] = (prefix_u64 & 0xFF) as u8;
    // bytes 6..32 already zero
    out
}

/// Read a 32-byte token's prefix as the 44-bit `n44` value used to look
/// up wordlist indices. Bytes 6..32 are ignored.
fn n44_from_token_prefix(token: &[u8]) -> u64 {
    debug_assert!(token.len() >= TOKEN_PREFIX_LEN);
    let mut n: u64 = 0;
    for &b in token.iter().take(TOKEN_PREFIX_LEN) {
        n = (n << 8) | b as u64;
    }
    n >> 4
}

/// Spec §8.6 encoding: 32-byte token → 4-word code, joined with `-`.
///
/// Only the first 6 bytes are read; the rest are ignored. Callers can
/// pass either a freshly-canonicalized token or any 32-byte buffer whose
/// first 6 bytes carry the code.
pub fn encode_code(token: &[u8; CANONICAL_TOKEN_LEN]) -> String {
    let n44 = n44_from_token_prefix(token);
    let w0 = (n44 >> 33) & 0x7FF;
    let w1 = (n44 >> 22) & 0x7FF;
    let w2 = (n44 >> 11) & 0x7FF;
    let w3 = n44 & 0x7FF;
    [w0, w1, w2, w3]
        .into_iter()
        .map(|i| BIP39_EN[i as usize])
        .collect::<Vec<_>>()
        .join("-")
}

/// Spec §8.6 decoding: 4-word code string → canonical 32-byte token.
/// Lowercases + splits on `-`; rejects unknown words.
pub fn decode_code(code: &str) -> Result<[u8; CANONICAL_TOKEN_LEN], InviteCodeError> {
    let code = code.trim().to_lowercase();
    let parts: Vec<&str> = code.split('-').collect();
    if parts.len() != CODE_WORDS {
        return Err(InviteCodeError::WrongWordCount {
            expected: CODE_WORDS,
            got: parts.len(),
        });
    }

    // Build a single global lookup map (lazy).
    let lookup = word_index_lookup();

    let mut indices = [0u64; CODE_WORDS];
    for (slot, word) in indices.iter_mut().zip(parts.iter()) {
        let idx = lookup
            .get(*word)
            .ok_or_else(|| InviteCodeError::UnknownWord((*word).to_string()))?;
        *slot = *idx as u64;
    }

    let n44 = (indices[0] << 33) | (indices[1] << 22) | (indices[2] << 11) | indices[3];
    Ok(canonical_token_from_n44(n44))
}

/// Build a {word → index} lookup map. Memoized via `OnceLock` so the
/// 2048-entry HashMap is allocated at most once for the process.
fn word_index_lookup() -> &'static HashMap<&'static str, u16> {
    static LOOKUP: std::sync::OnceLock<HashMap<&'static str, u16>> = std::sync::OnceLock::new();
    LOOKUP.get_or_init(|| {
        let mut m = HashMap::with_capacity(BIP39_EN.len());
        for (i, w) in BIP39_EN.iter().enumerate() {
            m.insert(*w, i as u16);
        }
        m
    })
}

/// Generate a fresh random invite. Returns:
///   - the canonical 32-byte token (sign over this for `ConsumeInvite`),
///   - the 4-word code (give this to the user),
///   - the SHA-256 of the canonical token (this is the DB primary key).
pub fn generate_invite() -> (
    [u8; CANONICAL_TOKEN_LEN],
    String,
    [u8; 32], // SHA-256(canonical)
) {
    // 44 bits of OS randomness — six bytes drawn, lower 4 bits discarded
    // by the `>> 4` step inside `canonical_token_from_n44`.
    let mut raw = [0u8; 8];
    rand::rngs::OsRng.fill_bytes(&mut raw);
    let n48 = u64::from_be_bytes([0, 0, raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]]);
    let n44 = n48 >> 4;
    let canonical = canonical_token_from_n44(n44);
    let code = encode_code(&canonical);
    let hash = sha256(&canonical);
    (canonical, code, hash)
}

/// SHA-256 helper. Public because the WS handshake needs to hash the
/// caller-supplied canonical token for the DB lookup.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(bytes);
    let out = h.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

/// One row in the `invites` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteRow {
    pub token_hash: Vec<u8>,
    pub inviter_id: i64,
    pub expires_at: DateTime<Utc>,
    pub consumed_at: Option<DateTime<Utc>>,
}

/// State of an invite for handler error mapping (spec §4.2 + §8.2 Error
/// frame codes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InviteState {
    Pending,
    Expired,
    Consumed,
}

impl InviteRow {
    /// Classify the row state against the current time.
    pub fn state(&self, now: DateTime<Utc>) -> InviteState {
        if self.consumed_at.is_some() {
            InviteState::Consumed
        } else if self.expires_at < now {
            InviteState::Expired
        } else {
            InviteState::Pending
        }
    }
}

/// Insert a fresh invite. Any outstanding (unconsumed) invites for the same
/// `inviter_id` are deleted first per spec §4.2 ("Creating a new one revokes
/// the prior").
pub async fn create_invite_record(
    pool: &PgPool,
    inviter_id: i64,
    token_hash: &[u8],
    expires_at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM invites WHERE inviter_id = $1 AND consumed_at IS NULL")
        .bind(inviter_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO invites (token_hash, inviter_id, expires_at) VALUES ($1, $2, $3)")
        .bind(token_hash)
        .bind(inviter_id)
        .bind(expires_at)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

type InviteDbRow = (Vec<u8>, i64, DateTime<Utc>, Option<DateTime<Utc>>);

/// Look up an invite by its token hash. Returns `None` if no such row.
pub async fn lookup_invite(pool: &PgPool, token_hash: &[u8]) -> sqlx::Result<Option<InviteRow>> {
    let row: Option<InviteDbRow> = sqlx::query_as(
        "SELECT token_hash, inviter_id, expires_at, consumed_at FROM invites WHERE token_hash = $1",
    )
    .bind(token_hash)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(
        |(token_hash, inviter_id, expires_at, consumed_at)| InviteRow {
            token_hash,
            inviter_id,
            expires_at,
            consumed_at,
        },
    ))
}

/// Atomically mark an invite consumed. Idempotent: if it was already
/// consumed, the row stays as-is.
pub async fn mark_consumed(
    pool: &PgPool,
    token_hash: &[u8],
    when: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query(
        "UPDATE invites SET consumed_at = $2 WHERE token_hash = $1 AND consumed_at IS NULL",
    )
    .bind(token_hash)
    .bind(when)
    .execute(pool)
    .await?;
    Ok(())
}

/// Compute the standard expiry for a freshly-created invite.
pub fn default_expiry(now: DateTime<Utc>) -> DateTime<Utc> {
    now + Duration::seconds(INVITE_TTL_SECONDS)
}

/// Render a QR PNG of `code` as base64.
///
/// Spec §4.3: the QR encodes the code string verbatim. No JSON, no URL
/// scheme — typing and scanning feed the same downstream code path.
pub fn qr_png_base64(code: &str) -> Result<String, QrError> {
    use base64::{engine::general_purpose::STANDARD as B64, Engine};
    use image::ImageEncoder;
    use qrcode::QrCode;

    let qr = QrCode::new(code.as_bytes()).map_err(|_| QrError::Encode)?;
    let img = qr.render::<image::Luma<u8>>().build();
    let mut png = Vec::new();
    image::codecs::png::PngEncoder::new(&mut png)
        .write_image(
            &img,
            img.width(),
            img.height(),
            image::ExtendedColorType::L8,
        )
        .map_err(|_| QrError::Render)?;
    Ok(B64.encode(&png))
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum QrError {
    #[error("QR encode failed")]
    Encode,
    #[error("PNG render failed")]
    Render,
}

// =========================================================================
// REST handler: POST /invites/{code}/preview (spec §8.1)
// =========================================================================

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::Serialize;

use crate::accounts::lookup_full_account_by_id;
use crate::ws::AppState;

#[derive(Debug, Serialize)]
pub struct InvitePreviewResponse {
    pub inviter_username: String,
    pub inviter_ed25519_pub: String,
    pub inviter_x25519_pub: String,
    pub expires_at: DateTime<Utc>,
}

/// Unauthenticated REST per spec §8.1. Kaitlyn may not have an account yet
/// when she pastes the code into her signup flow; possession of the code
/// is the only authorization.
pub async fn preview_invite(
    State(state): State<AppState>,
    Path(code): Path<String>,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };

    let canonical = match decode_code(&code) {
        Ok(t) => t,
        Err(_) => return (StatusCode::NOT_FOUND, "no such code").into_response(),
    };
    let token_hash = sha256(&canonical);

    let invite = match lookup_invite(store.pool(), &token_hash).await {
        Ok(Some(i)) => i,
        Ok(None) => return (StatusCode::NOT_FOUND, "no such code").into_response(),
        Err(e) => {
            tracing::warn!("lookup_invite failed: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };

    match invite.state(Utc::now()) {
        InviteState::Expired => return (StatusCode::GONE, "expired").into_response(),
        InviteState::Consumed => return (StatusCode::GONE, "consumed").into_response(),
        InviteState::Pending => {}
    }

    let inviter = match lookup_full_account_by_id(store, invite.inviter_id).await {
        Ok(Some(a)) => a,
        _ => return (StatusCode::NOT_FOUND, "no such code").into_response(),
    };

    Json(InvitePreviewResponse {
        inviter_username: inviter.username,
        inviter_ed25519_pub: B64.encode(&inviter.ed25519_pub),
        inviter_x25519_pub: B64.encode(&inviter.x25519_pub),
        expires_at: invite.expires_at,
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_encodes_then_decodes_identity() {
        for seed in [0u64, 1, 42, 0x123456789ABu64, (1u64 << CODE_BITS) - 1] {
            let canonical = canonical_token_from_n44(seed);
            let code = encode_code(&canonical);
            let back = decode_code(&code).expect("decode");
            assert_eq!(canonical, back, "round trip failed for seed {seed:#x}");
        }
    }

    #[test]
    fn encode_zero_token_is_four_abandons() {
        let canonical = canonical_token_from_n44(0);
        assert_eq!(encode_code(&canonical), "abandon-abandon-abandon-abandon");
    }

    #[test]
    fn encode_max_token_is_four_zoos() {
        let canonical = canonical_token_from_n44((1u64 << CODE_BITS) - 1);
        assert_eq!(encode_code(&canonical), "zoo-zoo-zoo-zoo");
    }

    #[test]
    fn decode_rejects_unknown_word() {
        let err = decode_code("abandon-abandon-abandon-bogusword").unwrap_err();
        assert!(matches!(err, InviteCodeError::UnknownWord(w) if w == "bogusword"));
    }

    #[test]
    fn decode_rejects_wrong_word_count() {
        let err = decode_code("abandon-abandon-abandon").unwrap_err();
        assert!(matches!(
            err,
            InviteCodeError::WrongWordCount {
                expected: 4,
                got: 3
            }
        ));
    }

    #[test]
    fn decode_is_case_insensitive() {
        let canonical = canonical_token_from_n44(0);
        let code = encode_code(&canonical);
        let upper = code.to_uppercase();
        assert_eq!(decode_code(&upper).unwrap(), canonical);
    }

    #[test]
    fn generate_invite_produces_consistent_hash() {
        let (canonical, code, hash) = generate_invite();
        assert_eq!(hash, sha256(&canonical));
        // Round-trip parity:
        let decoded = decode_code(&code).unwrap();
        assert_eq!(decoded, canonical);
    }

    #[test]
    fn canonical_token_zero_pads_bytes_six_to_thirty_two() {
        let token = canonical_token_from_n44(0x123456789AB);
        assert!(token[6..].iter().all(|&b| b == 0));
    }

    #[test]
    fn canonical_token_first_six_bytes_carry_the_44_bits() {
        let n44: u64 = 0x123456789AB;
        let token = canonical_token_from_n44(n44);
        // n44 << 4 = 0x123456789AB0 = bytes 12 34 56 78 9A B0
        assert_eq!(&token[..6], &[0x12, 0x34, 0x56, 0x78, 0x9A, 0xB0]);
    }
}
