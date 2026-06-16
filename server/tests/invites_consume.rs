//! Integration tests for the WS `ConsumeInvite` handler + the
//! `POST /invites/{code}/preview` REST endpoint (spec §4 + §8.1 + §8.2).

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, sign_invite_consume_b64,
    spawn_server,
};

/// End-to-end: court generates an invite, kaitlyn previews then consumes it,
/// both see the room.
#[file_serial(db)]
#[tokio::test]
async fn full_pairing_flow_succeeds() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;

    // 1. Court connects, creates invite.
    let mut court_sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court_sock).await;
    court_sock
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let invite_created = next_frame(&mut court_sock).await;
    let code = invite_created["code"].as_str().unwrap().to_string();

    // 2. Legacy v0.2-style CreateInvite leaves invites.room_id NULL, so the
    //    v0.3 roster-bearing preview returns 404 — clients in this flow use
    //    the consume-time roster from InviteConsumed instead.
    let resp = reqwest::Client::new()
        .post(format!("http://{addr}/invites/{code}/preview"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);

    // 3. Kaitlyn connects, signs the canonical token, sends ConsumeInvite.
    let mut kaitlyn_sock = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn_sock).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&kaitlyn_sk, &canonical);
    kaitlyn_sock
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
    let consumed = next_frame(&mut kaitlyn_sock).await;
    assert_eq!(consumed["kind"], "InviteConsumed", "got {consumed}");
    let room_id = consumed["room_id"].as_str().unwrap().to_string();
    assert!(!room_id.is_empty());
    let members = consumed["members"].as_array().unwrap();
    let usernames: Vec<&str> = members
        .iter()
        .map(|m| m["username"].as_str().unwrap())
        .collect();
    assert!(usernames.contains(&"court"));
    assert!(usernames.contains(&"kaitlyn"));

    // 4. Court receives RoomCreated with the full roster.
    let room_created = next_frame(&mut court_sock).await;
    assert_eq!(room_created["kind"], "RoomCreated", "got {room_created}");
    assert_eq!(room_created["room_id"], room_id);
    let members = room_created["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
}

#[file_serial(db)]
#[tokio::test]
async fn consume_with_invalid_signature_returns_invalid_signature_error() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

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

    let mut kaitlyn_sock = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn_sock).await;
    // Send a syntactically valid but wrong signature (signed by a different key).
    let wrong_sk = SigningKey::from_bytes(&[42u8; 32]);
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let bad_sig = sign_invite_consume_b64(&wrong_sk, &canonical);
    kaitlyn_sock
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "ConsumeInvite",
                "code": code,
                "signature_over_token": bad_sig,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut kaitlyn_sock).await;
    assert_eq!(frame["kind"], "Error");
    assert_eq!(frame["code"], "InvalidSignature");
}

#[file_serial(db)]
#[tokio::test]
async fn consume_unknown_code_returns_invite_not_found() {
    let store = fresh_store().await;
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let mut sock = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut sock).await;
    let canonical =
        littlelove_api::invites::decode_code("abandon-abandon-abandon-abandon").unwrap();
    let sig = sign_invite_consume_b64(&kaitlyn_sk, &canonical);
    sock.send(WsMessage::Text(
        serde_json::json!({
            "kind": "ConsumeInvite",
            "code": "abandon-abandon-abandon-abandon",
            "signature_over_token": sig,
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "Error");
    assert_eq!(frame["code"], "InviteNotFound");
}

#[file_serial(db)]
#[tokio::test]
async fn preview_unknown_code_returns_404() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let resp = reqwest::Client::new()
        .post(format!(
            "http://{addr}/invites/abandon-abandon-abandon-abandon/preview"
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

#[file_serial(db)]
#[tokio::test]
async fn preview_with_garbage_code_returns_404() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let resp = reqwest::Client::new()
        .post(format!("http://{addr}/invites/not-a-real-code/preview"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}
