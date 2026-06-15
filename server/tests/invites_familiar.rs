//! Integration tests for the familiar-ownership invite flow (Plan A):
//! `CreateFamiliarInvite` mints a kind=familiar invite, and consuming it flips
//! the consumer to is_bot=TRUE owned by the inviter in their own 1:1 room.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server};

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

// NOTE: the full consume-side test is appended in a later task, which also adds
// the `sign_invite_consume_b64` import.
