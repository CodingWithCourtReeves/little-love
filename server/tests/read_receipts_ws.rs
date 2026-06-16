//! Integration: MarkRead from the recipient relays a Read frame to the sender,
//! and a fresh Subscribe replays the sender's message with read = true.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use std::collections::HashMap;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server, Ws};

fn x25519_b64(username: &str) -> String {
    let mut x = [0u8; 32];
    for (i, b) in username.bytes().enumerate().take(32) {
        x[i] = b;
    }
    B64.encode(x)
}

/// court + kaitlyn linked as partners with a shared room; both handshaked.
async fn paired_pair(
    store: &littlelove_api::store::Store,
    addr: std::net::SocketAddr,
    court_sk: &SigningKey,
    kait_sk: &SigningKey,
) -> (Ws, Ws, String) {
    let pool = store.pool();
    let (court_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'court'")
        .fetch_one(pool)
        .await
        .unwrap();
    let (kait_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'kaitlyn'")
        .fetch_one(pool)
        .await
        .unwrap();
    littlelove_api::rooms::set_partner_link(pool, court_id, kait_id)
        .await
        .unwrap();
    let room_id =
        littlelove_api::rooms::create_room_with_members(pool, court_id, Some(kait_id), String::new())
            .await
            .unwrap();
    let mut court = handshake_as(addr, "court", court_sk).await;
    drain_rooms(&mut court).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    (court, kaitlyn, room_id)
}

/// court sends one message (with a self-copy) to kaitlyn. Returns the message id.
async fn court_sends(court: &mut Ws, kaitlyn: &mut Ws, room_id: &str) -> String {
    let mut bodies = HashMap::new();
    bodies.insert(x25519_b64("kaitlyn"), "ct_for_kait".to_string());
    bodies.insert(x25519_b64("court"), "ct_for_self".to_string());
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "bodies": bodies,
                "client_msg_id": uuid::Uuid::new_v4().to_string(),
            })
            .to_string(),
        ))
        .await
        .unwrap();
    // kaitlyn's addressed copy carries the authoritative id; court's self-echo
    // follows but we read kaitlyn's here.
    let to_kait = next_frame(kaitlyn).await;
    assert_eq!(to_kait["body"], "ct_for_kait");
    let _self_echo = next_frame(court).await; // drain court's live self-copy
    to_kait["id"].as_str().unwrap().to_string()
}

#[file_serial(db)]
#[tokio::test]
async fn mark_read_relays_read_frame_to_sender() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;
    let msg_id = court_sends(&mut court, &mut kaitlyn, &room_id).await;

    // Kaitlyn opens the chat and acks everything up to msg_id.
    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "MarkRead",
                "room_id": room_id,
                "up_to_message_id": msg_id,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // Court (the sender) receives a Read frame naming the read message.
    let read = next_frame(&mut court).await;
    assert_eq!(read["kind"], "Read", "{read}");
    assert_eq!(read["room_id"], room_id);
    assert_eq!(read["reader"], "kaitlyn");
    assert_eq!(read["message_ids"][0], msg_id);
}

#[file_serial(db)]
#[tokio::test]
async fn subscribe_replays_read_flag_after_partner_reads() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;
    let msg_id = court_sends(&mut court, &mut kaitlyn, &room_id).await;

    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "MarkRead",
                "room_id": room_id,
                "up_to_message_id": msg_id,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    // Drain the Read frame court receives so it doesn't bleed into the next read.
    let _ = next_frame(&mut court).await;

    // Court reconnects and replays history: the self-copy is now read.
    drop(court);
    let mut court2 = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court2).await;
    court2
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Subscribe",
                "room_id": room_id,
                "since_message_id": null,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let replayed = next_frame(&mut court2).await;
    assert_eq!(replayed["body"], "ct_for_self");
    assert_eq!(replayed["replayed"], true);
    assert_eq!(replayed["read"], true, "{replayed}");
}
