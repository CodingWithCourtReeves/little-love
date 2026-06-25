//! Invites: BIP39-encoded 4-word codes + DB persistence + REST preview.
//!
//! Spec: §4 (Pairing & Invites), §8.1 (`POST /invites/{code}/preview`),
//! §8.2 (CreateInvite/ConsumeInvite/InviteCreated/InviteConsumed frames),
//! §8.6 (BIP39 invite encoding).
//!
//! Pure-crypto primitives (BIP39 encode/decode, canonical token,
//! `generate_invite`, `sha256`) live in `littlelove_crypto::invite`.

use chrono::{DateTime, Duration, Utc};
use sqlx::PgPool;
use thiserror::Error;

pub use littlelove_crypto::invite::{
    canonical_token_from_n44, decode_code, encode_code, generate_invite, sha256, InviteCodeError,
    CANONICAL_TOKEN_LEN, CODE_WORDS,
};

/// Invites expire 1 hour after creation per spec §4.2.
pub const INVITE_TTL_SECONDS: i64 = 60 * 60;

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
///
/// `room_id` is `Some(_)` when the invite is created by `CreateRoom { invite_human_partner: true }`
/// (the consumer joins the existing room) and `None` for the legacy `CreateInvite` WSS frame
/// (the consume handler then creates a couple-only room on the fly).
pub async fn create_invite_record(
    pool: &PgPool,
    inviter_id: i64,
    token_hash: &[u8],
    expires_at: DateTime<Utc>,
    room_id: Option<&str>,
) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM invites WHERE inviter_id = $1 AND consumed_at IS NULL")
        .bind(inviter_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO invites (token_hash, inviter_id, expires_at, room_id)
         VALUES ($1, $2, $3, $4)",
    )
    .bind(token_hash)
    .bind(inviter_id)
    .bind(expires_at)
    .bind(room_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// The `room_id` the invite is tied to, if any. `None` means the invite was
/// created via the legacy v0.2 `CreateInvite` WSS path — the consume handler
/// should create a couple-only room on the fly.
pub async fn room_for_invite(pool: &PgPool, token_hash: &[u8]) -> sqlx::Result<Option<String>> {
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT room_id FROM invites WHERE token_hash = $1")
            .bind(token_hash)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(r,)| r))
}

type InviteDbRow = (Vec<u8>, i64, DateTime<Utc>, Option<DateTime<Utc>>);

/// Look up an invite by its token hash. Returns `None` if no such row.
pub async fn lookup_invite(pool: &PgPool, token_hash: &[u8]) -> sqlx::Result<Option<InviteRow>> {
    let row: Option<InviteDbRow> = sqlx::query_as(
        "SELECT token_hash, inviter_id, expires_at, consumed_at
         FROM invites WHERE token_hash = $1",
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
use serde::Serialize;

use crate::ws::AppState;

/// Invite preview (spec §8.1) — full room roster so the joining client can
/// render the inviting partner and choose whether to proceed. Legacy v0.2
/// invites (no `invites.room_id`) return 404; the client always issues
/// CreateRoom + invite_human_partner together.
#[derive(Debug, Serialize)]
pub struct InvitePreviewResponse {
    pub room_id: String,
    pub name: String,
    pub members: Vec<crate::wire::Member>,
    pub expires_at: DateTime<Utc>,
}

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
            tracing::error!("lookup_invite failed: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };

    match invite.state(Utc::now()) {
        InviteState::Expired => return (StatusCode::GONE, "expired").into_response(),
        InviteState::Consumed => return (StatusCode::GONE, "consumed").into_response(),
        InviteState::Pending => {}
    }

    let room_id = match room_for_invite(store.pool(), &token_hash).await {
        Ok(Some(r)) => r,
        Ok(None) => return (StatusCode::NOT_FOUND, "invite not bound to a room").into_response(),
        Err(e) => {
            tracing::error!("room_for_invite: {e}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "db error").into_response();
        }
    };
    let detail = match crate::rooms::room_detail(store.pool(), &room_id).await {
        Ok(Some(d)) => d,
        _ => return (StatusCode::NOT_FOUND, "room gone").into_response(),
    };

    Json(InvitePreviewResponse {
        room_id: detail.room_id,
        name: detail.name,
        members: detail
            .members
            .into_iter()
            .map(crate::rooms::Member::into_wire)
            .collect(),
        expires_at: invite.expires_at,
    })
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_state_classifies_against_now() {
        let now = Utc::now();
        let pending = InviteRow {
            token_hash: vec![0u8; 32],
            inviter_id: 1,
            expires_at: now + Duration::seconds(60),
            consumed_at: None,
        };
        assert_eq!(pending.state(now), InviteState::Pending);

        let expired = InviteRow {
            expires_at: now - Duration::seconds(1),
            ..pending.clone()
        };
        assert_eq!(expired.state(now), InviteState::Expired);

        let consumed = InviteRow {
            consumed_at: Some(now),
            ..pending.clone()
        };
        assert_eq!(consumed.state(now), InviteState::Consumed);
    }
}
