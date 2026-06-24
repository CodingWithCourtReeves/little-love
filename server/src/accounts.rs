//! REST handlers for /accounts. See spec §8.1.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

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

/// Stamp `accounts.last_seen_at = now()` for `account_id`. Called when a
/// WebSocket session opens and when the account's last session closes, so the
/// partner can see "last seen …" while this account is offline.
pub async fn touch_last_seen(pool: &PgPool, account_id: i64) -> sqlx::Result<()> {
    sqlx::query("UPDATE accounts SET last_seen_at = now() WHERE id = $1")
        .bind(account_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Read `accounts.last_seen_at` for `account_id`. `None` if the account has
/// never had a session (column is NULL).
pub async fn last_seen_for(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Option<DateTime<Utc>>> {
    let row: Option<(Option<DateTime<Utc>>,)> =
        sqlx::query_as("SELECT last_seen_at FROM accounts WHERE id = $1")
            .bind(account_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(t,)| t))
}

/// Full account record needed by post-handshake handlers (CreateInvite,
/// ConsumeInvite, Subscribe, Send, CreateRoom, RenameRoom, LeaveRoom).
#[derive(Debug, Clone)]
pub struct AccountRecord {
    pub id: i64,
    pub username: String,
    pub ed25519_pub: Vec<u8>,
    pub x25519_pub: Vec<u8>,
    pub partner_account_id: Option<i64>,
}

type FullAccountRow = (i64, String, Vec<u8>, Vec<u8>, Option<i64>);

fn full_account_record(row: FullAccountRow) -> AccountRecord {
    let (id, username, ed25519_pub, x25519_pub, partner_account_id) = row;
    AccountRecord {
        id,
        username,
        ed25519_pub,
        x25519_pub,
        partner_account_id,
    }
}

const FULL_ACCOUNT_COLS: &str = "id, username, ed25519_pub, x25519_pub, partner_account_id";

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
    fn account_record_carries_partner_field() {
        let r = AccountRecord {
            id: 1,
            username: "court".into(),
            ed25519_pub: vec![0u8; 32],
            x25519_pub: vec![1u8; 32],
            partner_account_id: Some(2),
        };
        assert_eq!(r.partner_account_id, Some(2));
    }
}
