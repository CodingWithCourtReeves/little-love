//! Integration tests for room-scoped Send + Subscribe + multi-session fan-out.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, sign_invite_consume_b64,
    spawn_server,
};

/// Pair two accounts and return their pre-handshaked sockets + the new room_id.
async fn paired_pair(
    addr: std::net::SocketAddr,
    court_sk: &SigningKey,
    kaitlyn_sk: &SigningKey,
) -> (common::Ws, common::Ws, String) {
    let mut court = handshake_as(addr, "court", court_sk).await;
    drain_rooms(&mut court).await;
    court
        .send(WsMessage::Text(
            serde_json::json!({"kind": "CreateInvite"}).to_string(),
        ))
        .await
        .unwrap();
    let created = next_frame(&mut court).await;
    let code = created["code"].as_str().unwrap().to_string();

    let mut kaitlyn = handshake_as(addr, "kaitlyn", kaitlyn_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let canonical = littlelove_api::invites::decode_code(&code).unwrap();
    let sig = sign_invite_consume_b64(kaitlyn_sk, &canonical);
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
    let consumed = next_frame(&mut kaitlyn).await;
    let room_id = consumed["room_id"].as_str().unwrap().to_string();
    let _ = next_frame(&mut court).await;
    (court, kaitlyn, room_id)
}

#[file_serial(db)]
#[tokio::test]
async fn send_routes_to_room_members() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(addr, &court_sk, &kaitlyn_sk).await;

    let body = "ct1|ct2";
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "body": body,
                "client_msg_id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // Both sockets receive the Message (court too — sender gets server echo).
    let court_msg = next_frame(&mut court).await;
    let kaitlyn_msg = next_frame(&mut kaitlyn).await;
    for (label, m) in [("court", &court_msg), ("kaitlyn", &kaitlyn_msg)] {
        assert_eq!(m["kind"], "Message", "{label}: {m}");
        assert_eq!(m["room_id"], room_id, "{label}");
        assert_eq!(m["from"], "court", "{label}");
        assert_eq!(m["body"], body, "{label}");
    }

    // psql confirms ciphertext is stored opaquely (acceptance criterion #3).
    let stored: (String,) = sqlx::query_as("SELECT body FROM messages LIMIT 1")
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(stored.0, body);
}

#[file_serial(db)]
#[tokio::test]
async fn send_echoes_client_msg_id_to_sender_only() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(addr, &court_sk, &kaitlyn_sk).await;

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
    sock.send(WsMessage::Text(
        serde_json::json!({
            "kind": "Send",
            "room_id": "01ROOMTHATDOESNOTEXIST000",
            "body": "x",
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
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let (mut court, _kaitlyn, room_id) = paired_pair(addr, &court_sk, &kaitlyn_sk).await;

    // Send 2 messages.
    for body in ["a", "b"] {
        court
            .send(WsMessage::Text(
                serde_json::json!({
                    "kind": "Send",
                    "room_id": room_id,
                    "body": body,
                    "client_msg_id": uuid::Uuid::new_v4().to_string(),
                })
                .to_string(),
            ))
            .await
            .unwrap();
        // Echo back to sender.
        let _ = next_frame(&mut court).await;
    }

    // Reconnect court fresh and Subscribe — expect replay of both messages.
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
    assert_eq!(m1["body"], "a");
    assert_eq!(m1["replayed"], true);
    assert_eq!(m2["body"], "b");
    assert_eq!(m2["replayed"], true);
}

#[file_serial(db)]
#[tokio::test]
async fn multi_session_fanout_reaches_every_open_socket() {
    // Spec AC #4: two WSS connections per username receive every routed message.
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    let (mut court_a, mut kaitlyn, room_id) = paired_pair(addr, &court_sk, &kaitlyn_sk).await;
    // Court opens a SECOND session.
    let mut court_b = handshake_as(addr, "court", &court_sk).await;
    // court_b's Rooms frame will include the existing room.
    let rooms = next_frame(&mut court_b).await;
    assert_eq!(rooms["kind"], "Rooms");
    assert_eq!(rooms["rooms"][0]["room_id"], room_id);

    kaitlyn
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Send",
                "room_id": room_id,
                "body": "hi twice",
                "client_msg_id": uuid::Uuid::new_v4().to_string(),
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // Kaitlyn sees her own echo.
    let _ = next_frame(&mut kaitlyn).await;
    // Both court sessions receive the Message.
    let a = next_frame(&mut court_a).await;
    let b = next_frame(&mut court_b).await;
    assert_eq!(a["body"], "hi twice");
    assert_eq!(b["body"], "hi twice");
    assert_eq!(a["from"], "kaitlyn");
    assert_eq!(b["from"], "kaitlyn");
}
