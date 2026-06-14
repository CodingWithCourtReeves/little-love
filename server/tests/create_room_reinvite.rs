//! v0.3 spec §5.1 + §198: an already-paired user can re-invite their
//! existing partner to a new room — `CreateRoom { invite_human_partner: true }`
//! should generate a fresh `pending_invite` rather than rejecting with
//! AlreadyPaired (which is what v0.2-style `CreateInvite` does, and what
//! v0.3 used to do up to commit ba1de2a).

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
async fn create_room_with_invite_partner_succeeds_when_already_paired() {
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
    //    paired. Pre-fix this returned Error/AlreadyPaired; post-fix it
    //    creates a new room and a fresh pending_invite so kaitlyn can
    //    consume to join the new room.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "CreateRoom",
                "name": "travel",
                "bot_account_ids": [],
                "invite_human_partner": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut court).await;
    assert_eq!(
        frame["kind"], "RoomCreated",
        "expected RoomCreated, got {frame}",
    );
    assert_eq!(frame["name"], "travel");
    let pending = &frame["pending_invite"];
    assert!(
        pending.is_object(),
        "pending_invite should be populated, got {frame}",
    );
    assert!(pending["code"].as_str().unwrap().contains('-'));
}
