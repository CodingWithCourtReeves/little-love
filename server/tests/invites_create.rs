//! Integration tests for the WS `CreateInvite` handler (spec §4 + §8.2).

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server};

#[file_serial(db)]
#[tokio::test]
async fn create_invite_returns_a_four_word_code_and_qr() {
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "court", &sk).await;
    drain_rooms(&mut sock).await;

    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateInvite"}).to_string(),
    ))
    .await
    .unwrap();

    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "InviteCreated", "got {frame}");
    let code = frame["code"].as_str().unwrap();
    assert_eq!(code.split('-').count(), 4, "code = {code}");
    // QR base64 should be non-empty PNG data.
    let qr = frame["qr_png_base64"].as_str().unwrap();
    assert!(
        qr.len() > 100,
        "qr_png_base64 too short: {} bytes",
        qr.len()
    );
    // expires_at parses as a future timestamp.
    let expires: chrono::DateTime<chrono::Utc> =
        frame["expires_at"].as_str().unwrap().parse().unwrap();
    assert!(expires > chrono::Utc::now());
}

#[file_serial(db)]
#[tokio::test]
async fn second_create_invite_invalidates_the_first() {
    // Spec §4.2: "A user can have at most one outstanding invite at a time.
    // Creating a new one revokes the prior."
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;
    let mut sock = handshake_as(addr, "court", &sk).await;
    drain_rooms(&mut sock).await;

    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateInvite"}).to_string(),
    ))
    .await
    .unwrap();
    let first = next_frame(&mut sock).await;
    let first_code = first["code"].as_str().unwrap().to_string();

    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateInvite"}).to_string(),
    ))
    .await
    .unwrap();
    let second = next_frame(&mut sock).await;
    let second_code = second["code"].as_str().unwrap().to_string();

    // Codes are independent random draws; assert distinctness probabilistically
    // (4-word entropy ≈ 44 bits; collision probability is negligible).
    assert_ne!(first_code, second_code);

    // Verify the first code's hash is no longer present in the invites table.
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invites WHERE consumed_at IS NULL")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(count, 1, "exactly one outstanding invite expected");
}

#[file_serial(db)]
#[tokio::test]
async fn create_invite_rejects_already_paired_caller() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;

    // Stuff a pre-existing room with both as members.
    let room_id = "01TESTROOM00000000000000000";
    sqlx::query("INSERT INTO rooms (id) VALUES ($1)")
        .bind(room_id)
        .execute(store.pool())
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO room_members (room_id, account_id)
         SELECT $1, id FROM accounts WHERE username = $2",
    )
    .bind(room_id)
    .bind("court")
    .execute(store.pool())
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO room_members (room_id, account_id)
         SELECT $1, id FROM accounts WHERE username = $2",
    )
    .bind(room_id)
    .bind("kaitlyn")
    .execute(store.pool())
    .await
    .unwrap();

    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut sock).await;

    sock.send(WsMessage::Text(
        serde_json::json!({"kind": "CreateInvite"}).to_string(),
    ))
    .await
    .unwrap();

    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "Error", "got {frame}");
    assert_eq!(frame["code"], "AlreadyPaired");
}
