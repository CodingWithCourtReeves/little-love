//! REST handlers for /accounts. See spec §8.1.

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::ws::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateAccountRequest {
    pub username: String,
    pub ed25519_pub: String,
    pub x25519_pub: String,
}

#[derive(Debug, Serialize)]
pub struct AccountSummary {
    pub username: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct AccountFull {
    pub username: String,
    pub ed25519_pub: String,
    pub x25519_pub: String,
    pub created_at: DateTime<Utc>,
}

/// Spec §3.1 step 1: 3–20 chars, `[a-z0-9_]`.
fn username_ok(u: &str) -> bool {
    let len = u.len();
    (3..=20).contains(&len)
        && u.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

fn decode_pubkey(s: &str) -> Option<Vec<u8>> {
    let bytes = B64.decode(s).ok()?;
    if bytes.len() == 32 {
        Some(bytes)
    } else {
        None
    }
}

pub async fn create_account(
    State(state): State<AppState>,
    Json(req): Json<CreateAccountRequest>,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };
    if !username_ok(&req.username) {
        return (StatusCode::BAD_REQUEST, "invalid username").into_response();
    }
    let ed = match decode_pubkey(&req.ed25519_pub) {
        Some(b) => b,
        None => return (StatusCode::BAD_REQUEST, "invalid ed25519_pub").into_response(),
    };
    let x = match decode_pubkey(&req.x25519_pub) {
        Some(b) => b,
        None => return (StatusCode::BAD_REQUEST, "invalid x25519_pub").into_response(),
    };

    let row: Result<(DateTime<Utc>,), sqlx::Error> = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ($1, $2, $3)
         RETURNING created_at",
    )
    .bind(&req.username)
    .bind(&ed)
    .bind(&x)
    .fetch_one(store.pool())
    .await;

    match row {
        Ok((created_at,)) => (
            StatusCode::CREATED,
            Json(AccountSummary {
                username: req.username,
                created_at,
            }),
        )
            .into_response(),
        Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("23505") => {
            (StatusCode::CONFLICT, "username taken").into_response()
        }
        Err(e) => {
            tracing::warn!("create_account db error: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response()
        }
    }
}

type AccountRow = (String, Vec<u8>, Vec<u8>, DateTime<Utc>);

pub async fn get_account_by_username(
    State(state): State<AppState>,
    Path(username): Path<String>,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };
    let row: Result<Option<AccountRow>, sqlx::Error> = sqlx::query_as(
        "SELECT username, ed25519_pub, x25519_pub, created_at
             FROM accounts WHERE username = $1",
    )
    .bind(&username)
    .fetch_optional(store.pool())
    .await;
    match row {
        Ok(Some((u, ed, x, ts))) => Json(AccountFull {
            username: u,
            ed25519_pub: B64.encode(&ed),
            x25519_pub: B64.encode(&x),
            created_at: ts,
        })
        .into_response(),
        Ok(None) => (StatusCode::NOT_FOUND, "no such account").into_response(),
        Err(e) => {
            tracing::warn!("get_account db error: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response()
        }
    }
}

/// Fetch the Ed25519 public key for the given username, if any.
/// Used by the WSS handshake to verify the signature in `Identify`.
pub async fn lookup_ed25519_pub(
    store: &crate::store::Store,
    username: &str,
) -> sqlx::Result<Option<Vec<u8>>> {
    let row: Option<(Vec<u8>,)> =
        sqlx::query_as("SELECT ed25519_pub FROM accounts WHERE username = $1")
            .bind(username)
            .fetch_optional(store.pool())
            .await?;
    Ok(row.map(|(b,)| b))
}

/// Full account record needed by post-handshake handlers (CreateInvite,
/// ConsumeInvite, Subscribe, Send, CreateRoom, RenameRoom, LeaveRoom).
#[derive(Debug, Clone)]
pub struct AccountRecord {
    pub id: i64,
    pub username: String,
    pub ed25519_pub: Vec<u8>,
    pub x25519_pub: Vec<u8>,
    pub is_bot: bool,
    pub owner_account_id: Option<i64>,
    pub partner_account_id: Option<i64>,
}

type FullAccountRow = (
    i64,
    String,
    Vec<u8>,
    Vec<u8>,
    bool,
    Option<i64>,
    Option<i64>,
);

fn full_account_record(row: FullAccountRow) -> AccountRecord {
    let (id, username, ed25519_pub, x25519_pub, is_bot, owner_account_id, partner_account_id) = row;
    AccountRecord {
        id,
        username,
        ed25519_pub,
        x25519_pub,
        is_bot,
        owner_account_id,
        partner_account_id,
    }
}

const FULL_ACCOUNT_COLS: &str =
    "id, username, ed25519_pub, x25519_pub, is_bot, owner_account_id, partner_account_id";

/// Fetch the full account record by username. None if no such account.
pub async fn lookup_full_account(
    store: &crate::store::Store,
    username: &str,
) -> sqlx::Result<Option<AccountRecord>> {
    let sql = format!("SELECT {FULL_ACCOUNT_COLS} FROM accounts WHERE username = $1");
    let row: Option<FullAccountRow> = sqlx::query_as(&sql)
        .bind(username)
        .fetch_optional(store.pool())
        .await?;
    Ok(row.map(full_account_record))
}

/// Fetch the full account record by integer id. Used by ConsumeInvite to
/// look up the inviter once the invite row resolves.
pub async fn lookup_full_account_by_id(
    store: &crate::store::Store,
    account_id: i64,
) -> sqlx::Result<Option<AccountRecord>> {
    let sql = format!("SELECT {FULL_ACCOUNT_COLS} FROM accounts WHERE id = $1");
    let row: Option<FullAccountRow> = sqlx::query_as(&sql)
        .bind(account_id)
        .fetch_optional(store.pool())
        .await?;
    Ok(row.map(full_account_record))
}

// =========================================================================
// v0.3 bot registration: POST /accounts/bot, DELETE /accounts/bot/{label}
// =========================================================================

/// `[a-z0-9-]{1,32}` — bot labels are display-time strings, joined to the
/// owner's username to form the on-account `bot_username`.
fn bot_label_ok(label: &str) -> bool {
    (1..=32).contains(&label.len())
        && label
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Bot usernames are owner-derived so v0.3 accepts `_` and `-` in the
/// non-leading positions, and they may run up to 32 chars (vs 20 for humans).
fn bot_username_ok(u: &str) -> bool {
    let len = u.len();
    (1..=32).contains(&len)
        && u.bytes().enumerate().all(|(i, b)| {
            if i == 0 {
                b.is_ascii_lowercase() || b.is_ascii_digit()
            } else {
                b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-'
            }
        })
}

#[derive(Debug, Deserialize)]
pub struct CreateBotRequest {
    pub owner_username: String,
    pub bot_label: String,
    pub bot_username: String,
    pub bot_ed25519_pub: String,
    pub bot_x25519_pub: String,
    pub owner_signature: String,
}

#[derive(Debug, Serialize)]
pub struct CreateBotResponse {
    pub account_id: i64,
    pub bot_username: String,
    pub is_bot: bool,
}

/// POST /accounts/bot — owner-signed familiar registration (spec §8.5.1
/// `littlelove.v0.3.bot-register`). Idempotent on `(owner, bot_username)`.
pub async fn create_bot_account(
    State(state): State<crate::ws::AppState>,
    Json(req): Json<CreateBotRequest>,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };
    if !bot_label_ok(&req.bot_label) {
        return (StatusCode::BAD_REQUEST, "invalid bot_label").into_response();
    }
    if !bot_username_ok(&req.bot_username) {
        return (StatusCode::BAD_REQUEST, "invalid bot_username").into_response();
    }
    let owner = match lookup_full_account(store, &req.owner_username).await {
        Ok(Some(a)) => a,
        _ => return (StatusCode::UNAUTHORIZED, "no such owner").into_response(),
    };
    if owner.is_bot {
        return (StatusCode::UNAUTHORIZED, "owner must be human").into_response();
    }
    // Enforce the canonical bot_username = "{owner}-{label}" so the owner
    // can't be tricked into authorising a familiar that squats on another
    // human's username namespace.
    let canonical_bot_username = format!("{}-{}", owner.username, req.bot_label);
    if req.bot_username != canonical_bot_username {
        return (
            StatusCode::BAD_REQUEST,
            "bot_username must equal owner-label",
        )
            .into_response();
    }
    let bot_ed = match decode_pubkey(&req.bot_ed25519_pub) {
        Some(b) => b,
        None => return (StatusCode::BAD_REQUEST, "bad bot_ed25519_pub").into_response(),
    };
    let bot_x = match decode_pubkey(&req.bot_x25519_pub) {
        Some(b) => b,
        None => return (StatusCode::BAD_REQUEST, "bad bot_x25519_pub").into_response(),
    };
    let sig = match B64.decode(&req.owner_signature) {
        Ok(s) => s,
        Err(_) => return (StatusCode::UNAUTHORIZED, "bad signature").into_response(),
    };
    // Binds both pubkeys so an attacker intercepting the request can't swap
    // bot_x25519_pub for their own (would otherwise let them MITM the E2E
    // channel).
    if littlelove_crypto::sig::verify_bot_register_signature(
        &owner.ed25519_pub,
        &bot_ed,
        &bot_x,
        &sig,
    )
    .is_err()
    {
        return (StatusCode::UNAUTHORIZED, "signature did not verify").into_response();
    }

    let existing: Option<(i64, String)> = sqlx::query_as(
        "SELECT id, username FROM accounts
         WHERE owner_account_id = $1 AND is_bot = TRUE AND username = $2",
    )
    .bind(owner.id)
    .bind(&req.bot_username)
    .fetch_optional(store.pool())
    .await
    .ok()
    .flatten();
    if let Some((id, u)) = existing {
        return (
            StatusCode::OK,
            Json(CreateBotResponse {
                account_id: id,
                bot_username: u,
                is_bot: true,
            }),
        )
            .into_response();
    }

    let row: Result<(i64,), sqlx::Error> = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub, is_bot, owner_account_id)
         VALUES ($1, $2, $3, TRUE, $4) RETURNING id",
    )
    .bind(&req.bot_username)
    .bind(&bot_ed)
    .bind(&bot_x)
    .bind(owner.id)
    .fetch_one(store.pool())
    .await;
    match row {
        Ok((id,)) => (
            StatusCode::CREATED,
            Json(CreateBotResponse {
                account_id: id,
                bot_username: req.bot_username,
                is_bot: true,
            }),
        )
            .into_response(),
        Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("23505") => {
            (StatusCode::CONFLICT, "bot_username taken").into_response()
        }
        Err(e) => {
            tracing::warn!("create_bot db: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response()
        }
    }
}

/// How long a delete-challenge nonce is valid for. Long enough for a normal
/// round-trip but short enough that a captured signature can only replay
/// inside this window — and only if no later challenge has overwritten the row.
const DELETE_CHALLENGE_TTL_SECONDS: i64 = 60;

#[derive(Debug, Serialize)]
pub struct DeleteChallengeResponse {
    pub nonce: String,
    pub expires_at: DateTime<Utc>,
}

/// POST /accounts/bot/{label}/delete-challenge — issue a one-time nonce that
/// the owner must sign and present alongside the DELETE. Anyone with the
/// owner_username can request a challenge (no auth gate here) — the security
/// comes from the DELETE requiring a valid signature over (label, nonce). The
/// composite-PK upsert means each new request invalidates the prior nonce.
pub async fn create_delete_challenge(
    State(state): State<crate::ws::AppState>,
    Path(label): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };
    let Some(owner_u) = headers
        .get("X-Owner-Username")
        .and_then(|v| v.to_str().ok())
    else {
        return (StatusCode::UNAUTHORIZED, "missing owner").into_response();
    };
    if !bot_label_ok(&label) {
        return (StatusCode::BAD_REQUEST, "invalid label").into_response();
    }
    let owner = match lookup_full_account(store, owner_u).await {
        Ok(Some(a)) => a,
        _ => return (StatusCode::UNAUTHORIZED, "no such owner").into_response(),
    };
    let nonce = littlelove_crypto::sig::random_nonce();
    let expires_at = Utc::now() + chrono::Duration::seconds(DELETE_CHALLENGE_TTL_SECONDS);
    let result = sqlx::query(
        "INSERT INTO bot_delete_challenges (owner_account_id, bot_label, nonce, expires_at)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (owner_account_id, bot_label)
         DO UPDATE SET nonce = EXCLUDED.nonce, expires_at = EXCLUDED.expires_at",
    )
    .bind(owner.id)
    .bind(&label)
    .bind(nonce.to_vec())
    .bind(expires_at)
    .execute(store.pool())
    .await;
    if let Err(e) = result {
        tracing::warn!("create_delete_challenge: {e}");
        return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
    }
    (
        StatusCode::OK,
        Json(DeleteChallengeResponse {
            nonce: B64.encode(nonce),
            expires_at,
        }),
    )
        .into_response()
}

/// DELETE /accounts/bot/{label} — owner-signed familiar deletion (spec §8.5.1
/// `littlelove.v0.3.bot-delete`). Signature covers `(label, nonce)` where
/// `nonce` was just issued by `POST /accounts/bot/{label}/delete-challenge`.
///
/// The signature verify is a pre-filter outside the transaction; the
/// replay-protection guarantee comes from the `DELETE … RETURNING` on
/// `bot_delete_challenges`, which atomically consumes the row that the
/// signature was issued against. Two concurrent requests with the same
/// captured (sig, nonce) pair both clear the verify, but only one wins the
/// DELETE race — the other returns 401.
pub async fn delete_bot_account(
    State(state): State<crate::ws::AppState>,
    Path(label): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let store = match state.store.as_ref() {
        Some(s) => s,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "store unavailable").into_response(),
    };
    let owner_username = headers
        .get("X-Owner-Username")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let sig_b64 = headers
        .get("X-Owner-Signature")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let nonce_b64 = headers
        .get("X-Delete-Nonce")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let (Some(owner_u), Some(sig_b64), Some(nonce_b64)) = (owner_username, sig_b64, nonce_b64)
    else {
        return (StatusCode::UNAUTHORIZED, "missing auth").into_response();
    };
    if !bot_label_ok(&label) {
        return (StatusCode::BAD_REQUEST, "invalid label").into_response();
    }
    let owner = match lookup_full_account(store, &owner_u).await {
        Ok(Some(a)) => a,
        _ => return (StatusCode::UNAUTHORIZED, "no such owner").into_response(),
    };
    let sig = match B64.decode(&sig_b64) {
        Ok(s) => s,
        Err(_) => return (StatusCode::UNAUTHORIZED, "bad sig").into_response(),
    };
    let nonce = match B64.decode(&nonce_b64) {
        Ok(n) => n,
        Err(_) => return (StatusCode::UNAUTHORIZED, "bad nonce").into_response(),
    };
    if littlelove_crypto::sig::verify_bot_delete_signature(
        &owner.ed25519_pub,
        label.as_bytes(),
        &nonce,
        &sig,
    )
    .is_err()
    {
        return (StatusCode::UNAUTHORIZED, "signature did not verify").into_response();
    }
    let mut tx = match store.pool().begin().await {
        Ok(tx) => tx,
        Err(e) => {
            tracing::warn!("delete_bot tx begin: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };
    // Consume the challenge: row must exist for this owner+label, with a
    // matching nonce, and not be expired. DELETE … RETURNING gives us
    // atomic check-and-consume, so a captured signature cannot replay.
    let consumed = sqlx::query(
        "DELETE FROM bot_delete_challenges
         WHERE owner_account_id = $1 AND bot_label = $2 AND nonce = $3 AND expires_at > NOW()
         RETURNING owner_account_id",
    )
    .bind(owner.id)
    .bind(&label)
    .bind(&nonce)
    .fetch_optional(&mut *tx)
    .await;
    let consumed = match consumed {
        Ok(row) => row,
        Err(e) => {
            tracing::warn!("delete_bot consume challenge: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };
    if consumed.is_none() {
        return (StatusCode::UNAUTHORIZED, "challenge expired or unknown").into_response();
    }
    let bot_username = format!("{owner_u}-{label}");
    let result = sqlx::query(
        "DELETE FROM accounts WHERE username = $1 AND is_bot = TRUE AND owner_account_id = $2",
    )
    .bind(&bot_username)
    .bind(owner.id)
    .execute(&mut *tx)
    .await;
    let rows_affected = match result {
        Ok(r) => r.rows_affected(),
        Err(e) => {
            tracing::warn!("delete_bot: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };
    if let Err(e) = tx.commit().await {
        tracing::warn!("delete_bot tx commit: {e}");
        return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
    }
    if rows_affected == 0 {
        (StatusCode::NOT_FOUND, "no such bot").into_response()
    } else {
        StatusCode::NO_CONTENT.into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn username_ok_accepts_valid() {
        for u in ["court", "kaitlyn", "abc", "abcdefghij1234567890", "a_b_c"] {
            assert!(username_ok(u), "{u} should be ok");
        }
    }

    #[test]
    fn username_ok_rejects_invalid() {
        for u in [
            "ab",
            "Court",
            "co-urt",
            "co.urt",
            "court!",
            &"a".repeat(21),
            "",
        ] {
            assert!(!username_ok(u), "{u} should be invalid");
        }
    }

    #[test]
    fn decode_pubkey_accepts_32_bytes() {
        assert!(decode_pubkey("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").is_some());
    }

    #[test]
    fn decode_pubkey_rejects_wrong_length() {
        assert!(decode_pubkey("AAAA").is_none());
    }

    #[test]
    fn bot_label_ok_accepts_lowercase_digits_dash() {
        for label in ["garden", "g", "a1", "x-y", &"z".repeat(32)] {
            assert!(bot_label_ok(label), "{label} should be ok");
        }
    }

    #[test]
    fn bot_label_ok_rejects_invalid() {
        for label in ["", "Garden", "g_arden", "g.arden", &"z".repeat(33)] {
            assert!(!bot_label_ok(label), "{label} should be invalid");
        }
    }

    #[test]
    fn bot_username_ok_accepts_dash_and_underscore() {
        for u in ["court-garden", "c1", "abc_def-ghi", "a"] {
            assert!(bot_username_ok(u), "{u} should be ok");
        }
    }

    #[test]
    fn bot_username_ok_rejects_leading_dash_or_underscore() {
        for u in ["-bot", "_bot", "BOT", "", &"a".repeat(33)] {
            assert!(!bot_username_ok(u), "{u} should be invalid");
        }
    }

    #[test]
    fn account_record_carries_v0_3_fields() {
        let r = AccountRecord {
            id: 1,
            username: "court".into(),
            ed25519_pub: vec![0u8; 32],
            x25519_pub: vec![1u8; 32],
            is_bot: false,
            owner_account_id: None,
            partner_account_id: Some(2),
        };
        assert!(!r.is_bot);
        assert_eq!(r.owner_account_id, None);
        assert_eq!(r.partner_account_id, Some(2));
    }
}
