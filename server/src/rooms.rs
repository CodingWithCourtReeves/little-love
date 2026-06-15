//! Rooms: DB ops for room creation, membership, and fan-out resolution.
//!
//! Spec: §4 (Pairing), §5 (Rooms), §7 (Multi-Device fan-out),
//! §8.4 (Postgres schema for rooms + room_members).

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use ulid::Ulid;

use crate::wire::{Member as WireMember, RoomDetail as WireRoomDetail};

/// One member of a room, populated from `room_members` joined to `accounts`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Member {
    pub account_id: i64,
    pub username: String,
    pub ed25519_pub: Vec<u8>,
    pub x25519_pub: Vec<u8>,
    pub is_bot: bool,
    pub owner_username: Option<String>,
}

impl Member {
    pub fn into_wire(self) -> WireMember {
        WireMember {
            account_id: self.account_id,
            username: self.username,
            ed25519_pub: B64.encode(self.ed25519_pub),
            x25519_pub: B64.encode(self.x25519_pub),
            is_bot: self.is_bot,
            owner_username: self.owner_username,
        }
    }
}

/// A room with its full roster, used to build `RoomServerFrame::Rooms` /
/// `RoomCreated` / `InviteConsumed` payloads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomDetail {
    pub room_id: String,
    pub name: String,
    pub members: Vec<Member>,
    pub created_at: DateTime<Utc>,
}

impl RoomDetail {
    pub fn into_wire(self) -> WireRoomDetail {
        WireRoomDetail {
            room_id: self.room_id,
            name: self.name,
            members: self.members.into_iter().map(Member::into_wire).collect(),
            created_at: self.created_at,
        }
    }
}

type MemberDbRow = (i64, String, Vec<u8>, Vec<u8>, bool, Option<String>);

/// Familiars owned by `owner_id`, regardless of room membership.
/// Spec §8.2 amendment — populates the `owned_bots` field on the
/// post-Authenticated `Rooms` frame so the Create-Chat picker can list
/// familiars that aren't yet in any room.
pub async fn owned_bots_for_account(pool: &PgPool, owner_id: i64) -> sqlx::Result<Vec<Member>> {
    let rows: Vec<MemberDbRow> = sqlx::query_as(
        "SELECT a.id, a.username, a.ed25519_pub, a.x25519_pub, a.is_bot,
                owner.username AS owner_username
         FROM accounts a
         JOIN accounts owner ON owner.id = a.owner_account_id
         WHERE a.is_bot = TRUE AND a.owner_account_id = $1
         ORDER BY a.username ASC",
    )
    .bind(owner_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, u, ed, x, b, ow)| Member {
            account_id: id,
            username: u,
            ed25519_pub: ed,
            x25519_pub: x,
            is_bot: b,
            owner_username: ow,
        })
        .collect())
}

pub async fn members_for_room(pool: &PgPool, room_id: &str) -> sqlx::Result<Vec<Member>> {
    let rows: Vec<MemberDbRow> = sqlx::query_as(
        "SELECT a.id, a.username, a.ed25519_pub, a.x25519_pub, a.is_bot,
                owner.username AS owner_username
         FROM room_members m
         JOIN accounts a ON a.id = m.account_id
         LEFT JOIN accounts owner ON owner.id = a.owner_account_id
         WHERE m.room_id = $1
         ORDER BY m.joined_at ASC",
    )
    .bind(room_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, u, ed, x, b, ow)| Member {
            account_id: id,
            username: u,
            ed25519_pub: ed,
            x25519_pub: x,
            is_bot: b,
            owner_username: ow,
        })
        .collect())
}

pub async fn room_detail(pool: &PgPool, room_id: &str) -> sqlx::Result<Option<RoomDetail>> {
    let row: Option<(String, String, DateTime<Utc>)> =
        sqlx::query_as("SELECT id, name, created_at FROM rooms WHERE id = $1")
            .bind(room_id)
            .fetch_optional(pool)
            .await?;
    let Some((rid, name, created_at)) = row else {
        return Ok(None);
    };
    let members = members_for_room(pool, &rid).await?;
    Ok(Some(RoomDetail {
        room_id: rid,
        name,
        members,
        created_at,
    }))
}

/// Live-read of `accounts.partner_account_id` for `account_id`. The
/// handshake-time `AccountRecord` snapshot can be stale if another device of
/// the same human paired in parallel; CreateInvite / CreateRoom must re-read
/// before gating on "already paired".
pub async fn partner_account_id_for(pool: &PgPool, account_id: i64) -> sqlx::Result<Option<i64>> {
    let row: Option<(Option<i64>,)> =
        sqlx::query_as("SELECT partner_account_id FROM accounts WHERE id = $1")
            .bind(account_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(p,)| p))
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

/// True iff `account_id` is currently in any room. Used by tests; the
/// authoritative monogamy check now lives in `accounts.partner_account_id`
/// rather than the v0.2 unique index on `room_members.account_id`.
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

/// All rooms `account_id` is in, with full rosters. Ordered by `r.created_at`
/// ascending so the sidebar's "couples chat pinned at top" semantics are
/// stable across reconnects.
pub async fn list_rooms_for_account(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Vec<RoomDetail>> {
    let room_ids: Vec<(String,)> = sqlx::query_as(
        "SELECT r.id FROM rooms r
         JOIN room_members m ON m.room_id = r.id
         WHERE m.account_id = $1
         ORDER BY r.created_at ASC",
    )
    .bind(account_id)
    .fetch_all(pool)
    .await?;
    let mut out = Vec::with_capacity(room_ids.len());
    for (rid,) in room_ids {
        if let Some(d) = room_detail(pool, &rid).await? {
            out.push(d);
        }
    }
    Ok(out)
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum MonogamyError {
    #[error("the other account is not your partner")]
    WrongPartner,
}

#[derive(Debug, thiserror::Error)]
pub enum PairError {
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error(transparent)]
    Monogamy(#[from] MonogamyError),
}

/// Validate that `me` can pair with `peer` under the v0.3 monogamy rule
/// (spec §3.2): either both human accounts have no partner yet, or they
/// already point at each other.
///
/// **Read-only.** Racy on its own — concurrent writers can move the rows
/// between this read and any subsequent UPDATE. Use [`set_partner_link`] in
/// the ConsumeInvite path; that path does the same check inside a single
/// transaction with `FOR UPDATE` row locks. This helper is here for tests
/// and for early validation where a transient race is acceptable.
pub async fn monogamy_check(
    pool: &PgPool,
    me: i64,
    peer: i64,
) -> sqlx::Result<Result<(), MonogamyError>> {
    let row: (Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT (SELECT partner_account_id FROM accounts WHERE id = $1),
                (SELECT partner_account_id FROM accounts WHERE id = $2)",
    )
    .bind(me)
    .bind(peer)
    .fetch_one(pool)
    .await?;
    let (mine, theirs) = row;
    let ok = match (mine, theirs) {
        (None, None) => true,
        (Some(p), Some(q)) => p == peer && q == me,
        _ => false,
    };
    Ok(if ok {
        Ok(())
    } else {
        Err(MonogamyError::WrongPartner)
    })
}

/// Atomically validate the monogamy invariant and set `partner_account_id`
/// on both accounts. Single transaction; both rows locked `FOR UPDATE` in
/// canonical id-ascending order so concurrent ConsumeInvites racing on the
/// same user serialize instead of both passing the check. The partial
/// `UNIQUE (partner_account_id)` index on `accounts` (migration 0006) is a
/// defence-in-depth backstop if the app check is ever bypassed.
///
/// Idempotent: a no-op if both already point at each other.
pub async fn set_partner_link(pool: &PgPool, a: i64, b: i64) -> Result<(), PairError> {
    let mut tx = pool.begin().await?;
    let rows: Vec<(i64, Option<i64>)> = sqlx::query_as(
        "SELECT id, partner_account_id FROM accounts
         WHERE id IN ($1, $2)
         ORDER BY id
         FOR UPDATE",
    )
    .bind(a)
    .bind(b)
    .fetch_all(&mut *tx)
    .await?;
    let mut mine: Option<Option<i64>> = None;
    let mut theirs: Option<Option<i64>> = None;
    for (id, p) in rows {
        if id == a {
            mine = Some(p);
        }
        if id == b {
            theirs = Some(p);
        }
    }
    let (Some(mine), Some(theirs)) = (mine, theirs) else {
        return Err(MonogamyError::WrongPartner.into());
    };
    let ok = match (mine, theirs) {
        (None, None) => true,
        (Some(p), Some(q)) => p == b && q == a,
        _ => false,
    };
    if !ok {
        return Err(MonogamyError::WrongPartner.into());
    }
    sqlx::query(
        "UPDATE accounts SET partner_account_id = $2
         WHERE id = $1 AND partner_account_id IS NULL",
    )
    .bind(a)
    .bind(b)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE accounts SET partner_account_id = $2
         WHERE id = $1 AND partner_account_id IS NULL",
    )
    .bind(b)
    .bind(a)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// True iff `bot_id` is a familiar owned by `human_id` directly, or by the
/// partner of `human_id`. Spec §5.1 step 3: either of the room's humans may
/// bring a bot they own (or that their partner owns).
pub async fn bot_owned_by(pool: &PgPool, bot_id: i64, human_id: i64) -> sqlx::Result<bool> {
    let row: (Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT (SELECT owner_account_id FROM accounts WHERE id = $1 AND is_bot = TRUE),
                (SELECT partner_account_id FROM accounts WHERE id = $2)",
    )
    .bind(bot_id)
    .bind(human_id)
    .fetch_one(pool)
    .await?;
    let (owner, partner) = row;
    let Some(owner) = owner else {
        return Ok(false);
    };
    Ok(owner == human_id || matches!(partner, Some(p) if p == owner))
}

#[derive(Debug, thiserror::Error)]
pub enum CreateRoomError {
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

/// Create a room with `host` as the initiating human, optional `partner`
/// (the host's already-linked human partner — auto-added when CreateRoom
/// requests `invite_human_partner` and the requester is already paired),
/// and `bots` as the pre-joined familiar account_ids. When `partner` is
/// `None`, no second human is seeded; the host can either invite a
/// stranger via the returned pending_invite or never add one. Returns the
/// ULID `room_id`. Caller validates bot ownership via `bot_owned_by`
/// before calling — this function does not re-check.
pub async fn create_room_with_members(
    pool: &PgPool,
    host: i64,
    partner: Option<i64>,
    bots: &[i64],
    name: String,
) -> Result<String, CreateRoomError> {
    let room_id = Ulid::new().to_string();
    let mut tx = pool.begin().await?;
    sqlx::query("INSERT INTO rooms (id, name) VALUES ($1, $2)")
        .bind(&room_id)
        .bind(&name)
        .execute(&mut *tx)
        .await?;
    let extras = partner.into_iter().chain(bots.iter().copied());
    for account_id in std::iter::once(host).chain(extras) {
        sqlx::query(
            "INSERT INTO room_members (room_id, account_id) VALUES ($1, $2)
             ON CONFLICT DO NOTHING",
        )
        .bind(&room_id)
        .bind(account_id)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(room_id)
}

pub async fn rename_room(pool: &PgPool, room_id: &str, name: &str) -> sqlx::Result<()> {
    sqlx::query("UPDATE rooms SET name = $2 WHERE id = $1")
        .bind(room_id)
        .bind(name)
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LeaveOutcome {
    pub room_deleted: bool,
}

/// Remove `account_id` from `room_id`. If the room has no humans left
/// afterward, cascade-delete the room (and via ON DELETE CASCADE, its
/// invites + messages). The WS handler resolves remaining usernames via
/// `members_for_room` before issuing the `MemberLeft` broadcast.
pub async fn leave_room(
    pool: &PgPool,
    room_id: &str,
    account_id: i64,
) -> sqlx::Result<LeaveOutcome> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM room_members WHERE room_id = $1 AND account_id = $2")
        .bind(room_id)
        .bind(account_id)
        .execute(&mut *tx)
        .await?;
    let (humans,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM room_members m
         JOIN accounts a ON a.id = m.account_id
         WHERE m.room_id = $1 AND a.is_bot = FALSE",
    )
    .bind(room_id)
    .fetch_one(&mut *tx)
    .await?;
    let room_deleted = if humans == 0 {
        sqlx::query("DELETE FROM rooms WHERE id = $1")
            .bind(room_id)
            .execute(&mut *tx)
            .await?;
        true
    } else {
        false
    };
    tx.commit().await?;
    Ok(LeaveOutcome { room_deleted })
}
