//! v0.3 spec §5.1 + §198: an already-paired user can include their
//! existing partner in a new room. Because the server already knows both
//! sides' pubkeys (they paired previously), the new room is created with
//! both members seeded immediately — no `pending_invite`, no waiting room.
//! The partner's connected sessions receive a `RoomCreated` push the same
//! way they would for any other room they're a member of.
//!
//! When the requester is NOT yet paired, the same frame still mints a
//! `pending_invite` so a stranger can pair via the existing
//! ConsumeInvite flow.

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
async fn create_room_auto_adds_paired_partner_without_invite() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    // 1. court + kaitlyn pair via legacy CreateInvite.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    court
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let code = next_frame(&mut court).await["code"]
        .as_str()
        .unwrap()
        .to_string();
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(&kaitlyn_sk, &canonical);
    kaitlyn
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
    let _consumed = next_frame(&mut kaitlyn).await;
    let _court_room_created = next_frame(&mut court).await;

    // 2. court issues CreateRoom + invite_human_partner=true while already
    //    paired. Server should auto-add kaitlyn — no pending_invite, both
    //    members present, and kaitlyn receives RoomCreated immediately.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "CreateRoom",
                "name": "travel",
                "invite_human_partner": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let court_frame = next_frame(&mut court).await;
    assert_eq!(court_frame["kind"], "RoomCreated", "got {court_frame}");
    assert_eq!(court_frame["name"], "travel");
    assert!(
        court_frame["pending_invite"].is_null(),
        "pending_invite should be null for already-paired partner, got {court_frame}",
    );
    let members = court_frame["members"].as_array().expect("members array");
    let usernames: Vec<&str> = members
        .iter()
        .map(|m| m["username"].as_str().unwrap())
        .collect();
    assert!(usernames.contains(&"court"));
    assert!(usernames.contains(&"kaitlyn"));

    // 3. kaitlyn (still connected) receives the RoomCreated push for the
    //    new room with both members seeded.
    let kaitlyn_frame = next_frame(&mut kaitlyn).await;
    assert_eq!(kaitlyn_frame["kind"], "RoomCreated", "got {kaitlyn_frame}");
    assert_eq!(kaitlyn_frame["name"], "travel");
    assert!(kaitlyn_frame["pending_invite"].is_null());
    let kaitlyn_members = kaitlyn_frame["members"].as_array().expect("members array");
    assert_eq!(kaitlyn_members.len(), 2);
}

#[file_serial(db)]
#[tokio::test]
async fn create_room_mints_invite_when_partner_not_paired() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;

    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "CreateRoom",
                "name": "first room",
                "invite_human_partner": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut court).await;
    assert_eq!(frame["kind"], "RoomCreated", "got {frame}");
    let pending = &frame["pending_invite"];
    assert!(
        pending.is_object(),
        "expected pending_invite for stranger-pair flow, got {frame}",
    );
    assert!(pending["code"].as_str().unwrap().contains('-'));
}
