//! Integration tests for the familiar-ownership invite flow (Plan A):
//! `CreateFamiliarInvite` mints a kind=familiar invite, and consuming it flips
//! the consumer to is_bot=TRUE owned by the inviter in their own 1:1 room.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, sign_invite_consume_b64,
    spawn_server,
};

#[file_serial(db)]
#[tokio::test]
async fn create_familiar_invite_returns_four_word_code_and_qr() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let mut sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut sock).await;

    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateFamiliarInvite"}).to_string(),
    ))
    .await
    .unwrap();

    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "InviteCreated", "got {frame}");
    let code = frame["code"].as_str().unwrap();
    assert_eq!(code.split('-').count(), 4, "code = {code}");
    let qr = frame["qr_png_base64"].as_str().unwrap();
    assert!(qr.len() > 100, "qr too short: {} bytes", qr.len());
}

#[file_serial(db)]
#[tokio::test]
async fn create_familiar_invite_does_not_block_when_already_paired() {
    // Owners can own multiple familiars, so the familiar-invite path has no
    // ALREADY_PAIRED gate even when the owner already has a human partner.
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    // Mark court already paired with kaitlyn.
    sqlx::query(
        "UPDATE accounts a
         SET partner_account_id = (SELECT id FROM accounts WHERE username = $2)
         WHERE a.username = $1",
    )
    .bind("court")
    .bind("kaitlyn")
    .execute(store.pool())
    .await
    .unwrap();
    sqlx::query(
        "UPDATE accounts a
         SET partner_account_id = (SELECT id FROM accounts WHERE username = $2)
         WHERE a.username = $1",
    )
    .bind("kaitlyn")
    .bind("court")
    .execute(store.pool())
    .await
    .unwrap();
    let addr = spawn_server(Some(store)).await;

    let mut sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut sock).await;
    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateFamiliarInvite"}).to_string(),
    ))
    .await
    .unwrap();
    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "InviteCreated", "got {frame}");
}

#[file_serial(db)]
#[tokio::test]
async fn consume_familiar_invite_makes_consumer_a_bot_in_a_one_to_one_room() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let helper_sk = SigningKey::from_bytes(&[7u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    // The familiar starts life as an ordinary (is_bot=FALSE) account — exactly
    // what the bot CLI's `pair` subcommand signs up before consuming.
    insert_account(&store, "helper", &helper_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    // 1. Court mints a familiar invite.
    let mut court_sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court_sock).await;
    court_sock
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateFamiliarInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let invite_created = next_frame(&mut court_sock).await;
    let code = invite_created["code"].as_str().unwrap().to_string();

    // 2. The familiar consumes it.
    let mut helper_sock = handshake_as(addr, "helper", &helper_sk).await;
    drain_rooms(&mut helper_sock).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&helper_sk, &canonical);
    helper_sock
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // 3. The familiar receives InviteConsumed with a 1:1 roster where it is now
    //    a bot owned by court.
    let consumed = next_frame(&mut helper_sock).await;
    assert_eq!(consumed["kind"], "InviteConsumed", "got {consumed}");
    let room_id = consumed["room_id"].as_str().unwrap().to_string();
    assert!(!room_id.is_empty());
    let members = consumed["members"].as_array().unwrap();
    assert_eq!(members.len(), 2, "expected a 1:1 room, got {members:?}");
    let helper_member = members
        .iter()
        .find(|m| m["username"] == "helper")
        .expect("helper in roster");
    assert_eq!(helper_member["is_bot"], true, "consumer should be a bot");
    assert_eq!(helper_member["owner_username"], "court");

    // 4. Court receives RoomCreated for the same room.
    let room_created = next_frame(&mut court_sock).await;
    assert_eq!(room_created["kind"], "RoomCreated", "got {room_created}");
    assert_eq!(room_created["room_id"], room_id);

    // 5. DB is authoritative: the consumer row is is_bot=TRUE owned by court.
    let (is_bot, owner_id, court_id): (bool, Option<i64>, i64) = sqlx::query_as(
        "SELECT h.is_bot, h.owner_account_id,
                (SELECT id FROM accounts WHERE username='court')
         FROM accounts h WHERE h.username='helper'",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert!(is_bot, "helper.is_bot should be TRUE");
    assert_eq!(owner_id, Some(court_id), "helper owned by court");

    // 6. The invite row itself was marked consumed inside the same transaction.
    //    Asserting this keeps the suite from staying green if mark_consumed were
    //    dropped from consume_familiar_invite.
    let (consumed_at,): (Option<chrono::DateTime<chrono::Utc>>,) =
        sqlx::query_as("SELECT consumed_at FROM invites WHERE inviter_id = $1")
            .bind(court_id)
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert!(
        consumed_at.is_some(),
        "the familiar invite must be marked consumed after a successful consume"
    );
}

/// Atomicity: if a later step in the familiar-consume transaction fails, the
/// is_bot flip must roll back. We force the failure by passing a NONEXISTENT
/// inviter id so the inviter's `room_members` insert violates the FK to
/// `accounts(id)`, which aborts the whole transaction. The consumer row must
/// remain a flippable human (is_bot=FALSE, owner_account_id NULL).
#[file_serial(db)]
#[tokio::test]
async fn consume_familiar_invite_rolls_back_flip_on_failure() {
    use littlelove_api::rooms::consume_familiar_invite;

    let store = fresh_store().await;
    let helper_sk = SigningKey::from_bytes(&[7u8; 32]);
    insert_account(&store, "helper", &helper_sk.verifying_key()).await;
    let (consumer_id,): (i64,) =
        sqlx::query_as("SELECT id FROM accounts WHERE username = 'helper'")
            .fetch_one(store.pool())
            .await
            .unwrap();

    // A nonexistent inviter id: the inviter's room_members insert will violate
    // the account_id FK and roll the whole transaction back.
    let bogus_inviter = 9_999_999_i64;
    let token_hash = [42u8; 32];

    let result = consume_familiar_invite(
        store.pool(),
        consumer_id,
        bogus_inviter,
        &token_hash,
        chrono::Utc::now(),
    )
    .await;
    assert!(result.is_err(), "expected the transaction to fail, got {result:?}");

    // The flip must have rolled back: helper is still a flippable human.
    let (is_bot, owner_id): (bool, Option<i64>) =
        sqlx::query_as("SELECT is_bot, owner_account_id FROM accounts WHERE id = $1")
            .bind(consumer_id)
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert!(!is_bot, "is_bot flip must have rolled back");
    assert_eq!(owner_id, None, "owner_account_id must have rolled back");

    // No room row should have leaked from the aborted transaction.
    let (rooms,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM rooms")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(rooms, 0, "no room should leak from the rolled-back tx");
}

/// Single-use under concurrency: once an invite has been consumed, a second
/// distinct fresh account racing to consume the SAME familiar invite must lose.
/// Both accounts are flippable (is_bot=FALSE), so the flip guard alone wouldn't
/// stop the second one — the `rows_affected()` check on the in-transaction
/// `mark_consumed` makes the invite row the serialization point. The loser gets
/// `AlreadyConsumed` and its flip + room are rolled back.
#[file_serial(db)]
#[tokio::test]
async fn consume_familiar_invite_rejects_already_consumed_invite() {
    use littlelove_api::invites::{create_invite_record, default_expiry, generate_invite, InviteKind};
    use littlelove_api::rooms::{consume_familiar_invite, FamiliarConsumeError};

    let store = fresh_store().await;
    let inviter_sk = SigningKey::from_bytes(&[1u8; 32]);
    let consumer1_sk = SigningKey::from_bytes(&[7u8; 32]);
    let consumer2_sk = SigningKey::from_bytes(&[8u8; 32]);
    insert_account(&store, "court", &inviter_sk.verifying_key()).await;
    insert_account(&store, "helper1", &consumer1_sk.verifying_key()).await;
    insert_account(&store, "helper2", &consumer2_sk.verifying_key()).await;

    let ids = |u: &'static str| {
        let pool = store.pool().clone();
        async move {
            let (id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = $1")
                .bind(u)
                .fetch_one(&pool)
                .await
                .unwrap();
            id
        }
    };
    let inviter_id = ids("court").await;
    let consumer1_id = ids("helper1").await;
    let consumer2_id = ids("helper2").await;

    // INSERT a real familiar invite row so the first consume's mark_consumed
    // actually affects 1 row. token_hash is derived via the same generate_invite
    // flow the server uses.
    let now = chrono::Utc::now();
    let (_canonical, _code, token_hash) = generate_invite();
    create_invite_record(
        store.pool(),
        inviter_id,
        &token_hash,
        default_expiry(now),
        None,
        InviteKind::Familiar,
    )
    .await
    .unwrap();

    // First consumer wins.
    let first = consume_familiar_invite(store.pool(), consumer1_id, inviter_id, &token_hash, now)
        .await;
    assert!(first.is_ok(), "first consume should succeed, got {first:?}");

    // Second consumer races on the SAME (now consumed) invite and loses.
    let second = consume_familiar_invite(store.pool(), consumer2_id, inviter_id, &token_hash, now)
        .await;
    let err = second.expect_err("second consume must be rejected");
    assert!(
        matches!(err, FamiliarConsumeError::AlreadyConsumed),
        "expected AlreadyConsumed, got {err:?}"
    );

    // The loser's flip rolled back: helper2 is still a flippable human.
    let (is_bot2, owner2): (bool, Option<i64>) =
        sqlx::query_as("SELECT is_bot, owner_account_id FROM accounts WHERE id = $1")
            .bind(consumer2_id)
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert!(!is_bot2, "second consumer's is_bot flip must have rolled back");
    assert_eq!(owner2, None, "second consumer's owner must have rolled back");

    // Only the first consume's room exists — the loser's room rolled back.
    let (rooms,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM rooms")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(rooms, 1, "only the winner's room should exist");
}

/// Fix 1: a familiar (is_bot=TRUE) account must be rejected when it tries to
/// consume an invite. The top-of-handler guard returns NotPermitted before any
/// pairing/flip side-effect, so the inviter's invite stays pending.
#[file_serial(db)]
#[tokio::test]
async fn bot_cannot_consume_invite() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let bot_sk = SigningKey::from_bytes(&[8u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "bot", &bot_sk.verifying_key()).await;
    // Flip "bot" into a familiar owned by court (satisfies the
    // accounts_owner_only_for_bots CHECK).
    sqlx::query(
        "UPDATE accounts SET is_bot = TRUE,
             owner_account_id = (SELECT id FROM accounts WHERE username = 'court')
         WHERE username = 'bot'",
    )
    .execute(store.pool())
    .await
    .unwrap();
    let addr = spawn_server(Some(store.clone())).await;

    // Court mints a (partner) invite.
    let mut court_sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court_sock).await;
    court_sock
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code = next_frame(&mut court_sock).await["code"]
        .as_str()
        .unwrap()
        .to_string();

    // The bot tries to consume it.
    let mut bot_sock = handshake_as(addr, "bot", &bot_sk).await;
    drain_rooms(&mut bot_sock).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&bot_sk, &canonical);
    bot_sock
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // It gets a NotPermitted error frame.
    let resp = next_frame(&mut bot_sock).await;
    assert_eq!(resp["kind"], "Error", "got {resp}");
    assert_eq!(resp["code"], "NotPermitted", "got {resp}");

    // No side-effect: court and bot are not paired, and the invite is still
    // pending (not consumed).
    let (court_partner, bot_partner): (Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT (SELECT partner_account_id FROM accounts WHERE username = 'court'),
                (SELECT partner_account_id FROM accounts WHERE username = 'bot')",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!(court_partner, None, "court must not be paired");
    assert_eq!(bot_partner, None, "bot must not be paired");

    let (pending,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM invites
         WHERE inviter_id = (SELECT id FROM accounts WHERE username = 'court')
           AND consumed_at IS NULL",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!(pending, 1, "court's invite must still be pending");
}

/// Fix 2: invite revocation is scoped by kind. Minting a familiar invite must
/// NOT revoke a pending partner invite (and vice versa). Same-kind minting
/// still revokes the prior invite of that kind.
#[file_serial(db)]
#[tokio::test]
async fn invite_revocation_is_scoped_by_kind() {
    use littlelove_api::invites::{
        create_invite_record, default_expiry, generate_invite, InviteKind,
    };

    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let (court_id,): (i64,) =
        sqlx::query_as("SELECT id FROM accounts WHERE username = 'court'")
            .fetch_one(store.pool())
            .await
            .unwrap();
    let now = chrono::Utc::now();

    // 1. Mint a partner invite.
    let (_c1, _code1, partner_hash) = generate_invite();
    create_invite_record(
        store.pool(),
        court_id,
        &partner_hash,
        default_expiry(now),
        None,
        InviteKind::Partner,
    )
    .await
    .unwrap();

    // 2. Mint a familiar invite — must leave the partner invite intact.
    let (_c2, _code2, familiar_hash) = generate_invite();
    create_invite_record(
        store.pool(),
        court_id,
        &familiar_hash,
        default_expiry(now),
        None,
        InviteKind::Familiar,
    )
    .await
    .unwrap();

    let (total,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM invites WHERE inviter_id = $1 AND consumed_at IS NULL")
            .bind(court_id)
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert_eq!(
        total, 2,
        "both partner and familiar invites should remain pending"
    );
    // The original partner invite specifically survives.
    let (partner_alive,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM invites WHERE token_hash = $1")
            .bind(&partner_hash[..])
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert_eq!(partner_alive, 1, "partner invite must not be revoked");

    // 3. Same-kind revocation still works: a second partner invite revokes the
    //    first partner invite but leaves the familiar invite alone.
    let (_c3, _code3, partner_hash2) = generate_invite();
    create_invite_record(
        store.pool(),
        court_id,
        &partner_hash2,
        default_expiry(now),
        None,
        InviteKind::Partner,
    )
    .await
    .unwrap();

    let (first_partner_gone,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM invites WHERE token_hash = $1")
            .bind(&partner_hash[..])
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert_eq!(first_partner_gone, 0, "first partner invite should be revoked");

    let (familiar_alive,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM invites WHERE token_hash = $1")
            .bind(&familiar_hash[..])
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert_eq!(familiar_alive, 1, "familiar invite must survive same-kind revoke");
}
