//! Rooms: DB ops for room creation, membership, and fan-out resolution.
//!
//! Spec: §4 (Pairing — `ConsumeInvite` creates rooms), §7 (Multi-Device fan-out),
//! §8.4 (Postgres schema for rooms + room_members).

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use ulid::Ulid;

use crate::wire::RoomSummary;

/// One row in the `Rooms` server frame — a couples chat the caller is in,
/// pre-joined with the peer's account info.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomSummaryRow {
    pub room_id: String,
    pub peer_account_id: i64,
    pub peer_username: String,
    pub peer_ed25519_pub: Vec<u8>,
    pub peer_x25519_pub: Vec<u8>,
    pub created_at: DateTime<Utc>,
}

impl RoomSummaryRow {
    /// Encode the peer pubkeys as base64 for the on-wire shape.
    pub fn into_wire(self) -> RoomSummary {
        use base64::{engine::general_purpose::STANDARD as B64, Engine};
        RoomSummary {
            room_id: self.room_id,
            peer_username: self.peer_username,
            peer_ed25519_pub: B64.encode(self.peer_ed25519_pub),
            peer_x25519_pub: B64.encode(self.peer_x25519_pub),
            created_at: self.created_at,
        }
    }
}

/// Fetch the integer `accounts.id` for a username. Returns `None` if no such
/// account exists.
pub async fn account_id_by_username(pool: &PgPool, username: &str) -> sqlx::Result<Option<i64>> {
    let row: Option<(i64,)> = sqlx::query_as("SELECT id FROM accounts WHERE username = $1")
        .bind(username)
        .fetch_optional(pool)
        .await?;
    Ok(row.map(|(id,)| id))
}

/// True iff `account_id` is currently in any room. Used to enforce the
/// monogamy constraint at the handler layer (the DB unique index on
/// `room_members.account_id` is the structural guarantee).
pub async fn is_paired(pool: &PgPool, account_id: i64) -> sqlx::Result<bool> {
    let row: Option<(i64,)> = sqlx::query_as(
        "SELECT 1::bigint AS exists FROM room_members WHERE account_id = $1 LIMIT 1",
    )
    .bind(account_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.is_some())
}

/// True iff `account_id` is a member of `room_id`. Used for Subscribe/Send
/// authorization.
pub async fn is_member(pool: &PgPool, room_id: &str, account_id: i64) -> sqlx::Result<bool> {
    let row: Option<(i64,)> = sqlx::query_as(
        "SELECT 1::bigint AS exists FROM room_members
         WHERE room_id = $1 AND account_id = $2 LIMIT 1",
    )
    .bind(room_id)
    .bind(account_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.is_some())
}

/// List the usernames of every member of `room_id`. Used by Send to fan-out
/// the resulting Message frame to each member's open sessions via
/// `Routing::deliver`.
pub async fn member_usernames(pool: &PgPool, room_id: &str) -> sqlx::Result<Vec<String>> {
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT a.username FROM room_members m
         JOIN accounts a ON a.id = m.account_id
         WHERE m.room_id = $1",
    )
    .bind(room_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(u,)| u).collect())
}

type RoomSummaryDbRow = (String, i64, String, Vec<u8>, Vec<u8>, DateTime<Utc>);

/// All rooms `account_id` is in, with peer info pre-joined. Returns rooms
/// ordered by `created_at` ascending (oldest first) so the inbox sidebar's
/// "couples chat pinned at top" semantics are stable across reconnects.
pub async fn list_rooms_for_account(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Vec<RoomSummaryRow>> {
    let rows: Vec<RoomSummaryDbRow> = sqlx::query_as(
        "SELECT r.id, peer.id, peer.username, peer.ed25519_pub, peer.x25519_pub, r.created_at
         FROM rooms r
         JOIN room_members me ON me.room_id = r.id AND me.account_id = $1
         JOIN room_members peer_link ON peer_link.room_id = r.id AND peer_link.account_id <> $1
         JOIN accounts peer ON peer.id = peer_link.account_id
         ORDER BY r.created_at ASC",
    )
    .bind(account_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(
            |(room_id, peer_account_id, peer_username, ed, x, created_at)| RoomSummaryRow {
                room_id,
                peer_account_id,
                peer_username,
                peer_ed25519_pub: ed,
                peer_x25519_pub: x,
                created_at,
            },
        )
        .collect())
}

/// Possible outcomes of `create_room_with_members`.
#[derive(Debug, thiserror::Error)]
pub enum CreateRoomError {
    #[error("account {0} is already paired")]
    AlreadyPaired(i64),
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

/// Transactional: create a new room and insert both members atomically.
/// Returns the new ULID `room_id`.
///
/// Returns `AlreadyPaired` if either account is already in a room. The
/// underlying guarantee is the unique index `room_members_one_per_account`
/// on `account_id` (migration 0004) — this function maps the resulting
/// 23505 to a structured error.
pub async fn create_room_with_members(
    pool: &PgPool,
    inviter_account_id: i64,
    consumer_account_id: i64,
) -> Result<String, CreateRoomError> {
    let room_id = Ulid::new().to_string();
    let mut tx = pool.begin().await?;

    sqlx::query("INSERT INTO rooms (id) VALUES ($1)")
        .bind(&room_id)
        .execute(&mut *tx)
        .await?;

    for account_id in [inviter_account_id, consumer_account_id] {
        let res = sqlx::query("INSERT INTO room_members (room_id, account_id) VALUES ($1, $2)")
            .bind(&room_id)
            .bind(account_id)
            .execute(&mut *tx)
            .await;
        if let Err(sqlx::Error::Database(db)) = &res {
            if db.code().as_deref() == Some("23505") {
                // Either the (room_id, account_id) PK or the unique
                // monogamy index fired. The former cannot happen here
                // because the ULID is fresh; only the monogamy index
                // matters in practice.
                tx.rollback().await?;
                return Err(CreateRoomError::AlreadyPaired(account_id));
            }
        }
        res?;
    }

    tx.commit().await?;
    Ok(room_id)
}
