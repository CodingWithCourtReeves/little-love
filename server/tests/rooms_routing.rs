//! Integration tests for room-scoped Send + Subscribe + multi-session fan-out
//! under v0.3: `Send.bodies` is a map keyed by each *recipient's* x25519_pub_b64
//! (sender is excluded), and the server never echoes back to the sender.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use std::collections::HashMap;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server, Ws,
};

/// x25519_pub bytes that `insert_account` assigns: the username bytes padded
/// with zeros to 32 bytes. Mirrors `server/tests/common/mod.rs::insert_account`.
fn x25519_for(username: &str) -> [u8; 32] {
    let mut x = [0u8; 32];
    for (i, b) in username.bytes().enumerate().take(32) {
        x[i] = b;
    }
    x
}

fn x25519_b64(username: &str) -> String {
    B64.encode(x25519_for(username))
}

/// Set up `court` + `kaitlyn` as a couple (partner_account_id linked) with a
/// shared room and return both pre-handshaked sockets + the room_id. Accounts
/// must already be inserted by the caller.
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
    let room_id = littlelove_api::rooms::create_room_with_members(
        pool,
        court_id,
        Some(kait_id),
        &[],
        String::new(),
    )
    .await
    .unwrap();

    let mut court = handshake_as(addr, "court", court_sk).await;
    drain_rooms(&mut court).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    (court, kaitlyn, room_id)
}

#[file_serial(db)]
#[tokio::test]
async fn send_routes_to_room_members() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    let mut bodies = HashMap::new();
    bodies.insert(x25519_b64("kaitlyn"), "ct_for_kait".to_string());

    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "bodies": bodies,
                "client_msg_id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
            })
            .to_string(),
        ))
        .await
        .unwrap();

    let m = next_frame(&mut kaitlyn).await;
    assert_eq!(m["kind"], "Message", "{m}");
    assert_eq!(m["room_id"], room_id);
    assert_eq!(m["from"], "court");
    assert_eq!(m["body"], "ct_for_kait");

    let stored: (String,) = sqlx::query_as(
        "SELECT body FROM messages m
         JOIN accounts a ON a.id = m.recipient_account_id
         WHERE a.username = 'kaitlyn'",
    )
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert_eq!(stored.0, "ct_for_kait");
}

#[file_serial(db)]
#[tokio::test]
async fn send_echoes_client_msg_id_to_sender_only() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) =
        paired_pair(&store, addr, &court_sk, &kaitlyn_sk).await;

    let client_msg_id = "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707";
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "body": "hi",
                "client_msg_id": client_msg_id,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    let court_msg = next_frame(&mut court).await;
    let kaitlyn_msg = next_frame(&mut kaitlyn).await;

    assert_eq!(
        court_msg["client_msg_id"].as_str(),
        Some(client_msg_id),
        "sender's echo must include the original client_msg_id"
    );
    assert!(
        kaitlyn_msg.get("client_msg_id").is_none(),
        "peer must not receive the sender's client_msg_id (got {kaitlyn_msg})"
    );
}

#[file_serial(db)]
#[tokio::test]
async fn send_to_unknown_room_returns_unknown_room_error() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let mut sock = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut sock).await;

    let mut bodies = HashMap::new();
    bodies.insert(x25519_b64("kaitlyn"), "ct".to_string());

    sock.send(WsMessage::Text(
        serde_json::json!({
            "kind": "Send",
            "room_id": "01ROOMTHATDOESNOTEXIST000",
            "bodies": bodies,
            "client_msg_id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let frame = next_frame(&mut sock).await;
    assert_eq!(frame["kind"], "Error");
    assert_eq!(frame["code"], "UnknownRoom");
}

#[file_serial(db)]
#[tokio::test]
async fn subscribe_replays_message_history() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    for tag in ["a", "b"] {
        let mut bodies = HashMap::new();
        bodies.insert(x25519_b64("court"), format!("ct_court_{tag}"));
        kaitlyn
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
        let _ = next_frame(&mut court).await;
    }

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
    let m1 = next_frame(&mut court2).await;
    let m2 = next_frame(&mut court2).await;
    assert_eq!(m1["body"], "ct_court_a");
    assert_eq!(m1["replayed"], true);
    assert_eq!(m2["body"], "ct_court_b");
    assert_eq!(m2["replayed"], true);
}

#[file_serial(db)]
#[tokio::test]
async fn self_copy_is_echoed_with_client_msg_id_and_replays() {
    // The sender may include a body addressed to their own key. The server
    // stores it as a self-row, echoes it back live carrying `client_msg_id`
    // (so the client can reconcile its optimistic echo), and replays it on a
    // fresh subscribe (without `client_msg_id`, since it isn't persisted).
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    let cmid = "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707";
    let mut bodies = HashMap::new();
    bodies.insert(x25519_b64("kaitlyn"), "ct_for_kait".to_string());
    bodies.insert(x25519_b64("court"), "ct_for_self".to_string());
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "bodies": bodies,
                "client_msg_id": cmid,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // Recipient gets their addressed body, no client_msg_id.
    let to_kait = next_frame(&mut kaitlyn).await;
    assert_eq!(to_kait["body"], "ct_for_kait");
    assert!(to_kait.get("client_msg_id").is_none(), "{to_kait}");

    // Sender gets the live self-copy echoed back with client_msg_id.
    let to_self = next_frame(&mut court).await;
    assert_eq!(to_self["from"], "court");
    assert_eq!(to_self["body"], "ct_for_self");
    assert_eq!(to_self["client_msg_id"], cmid);

    // Fresh session replays the self-copy without client_msg_id.
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
    assert!(replayed.get("client_msg_id").is_none(), "{replayed}");
}

#[file_serial(db)]
#[tokio::test]
async fn multi_session_fanout_reaches_every_open_socket() {
    // Spec AC #4: two WSS sessions per username both receive routed messages.
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court_a, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;
    let mut court_b = handshake_as(addr, "court", &court_sk).await;
    let rooms = next_frame(&mut court_b).await;
    assert_eq!(rooms["kind"], "Rooms");
    assert_eq!(rooms["rooms"][0]["room_id"], room_id);

    let mut bodies = HashMap::new();
    bodies.insert(x25519_b64("court"), "ct_for_court".to_string());
    kaitlyn
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

    let a = next_frame(&mut court_a).await;
    let b = next_frame(&mut court_b).await;
    assert_eq!(a["body"], "ct_for_court");
    assert_eq!(b["body"], "ct_for_court");
    assert_eq!(a["from"], "kaitlyn");
    assert_eq!(b["from"], "kaitlyn");
}
