use std::time::Duration;

use ed25519_dalek::SigningKey;
use futures::{SinkExt, StreamExt};
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{fresh_store, handshake_as, insert_account, spawn_server};

#[tokio::test]
#[file_serial(db)]
async fn forwards_message_to_recipient_when_both_connected() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;
    let mut court = handshake_as(addr, "court", &court_sk).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;

    tokio::time::sleep(Duration::from_millis(50)).await;

    let frame = serde_json::json!({
        "type": "msg",
        "id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "from": "court",
        "to": "kaitlyn",
        "body": "hey love",
        "ts": "2026-06-09T17:00:00Z"
    });
    court
        .send(WsMessage::Text(frame.to_string()))
        .await
        .unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), kaitlyn.next())
        .await
        .expect("recv within 2s")
        .expect("stream open")
        .expect("recv ok");
    let text = match received {
        WsMessage::Text(t) => t,
        other => panic!("expected text frame, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["from"], "court");
    assert_eq!(value["to"], "kaitlyn");
    assert_eq!(value["body"], "hey love");
}

#[tokio::test]
#[file_serial(db)]
async fn server_overrides_from_with_authenticated_username() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;
    let mut court = handshake_as(addr, "court", &court_sk).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;

    tokio::time::sleep(Duration::from_millis(50)).await;

    // Court is authenticated as "court" but spoofs from=eve in the payload.
    let frame = serde_json::json!({
        "type": "msg",
        "id": "8c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "from": "eve",
        "to": "kaitlyn",
        "body": "fake",
        "ts": "2026-06-09T17:00:00Z"
    });
    court
        .send(WsMessage::Text(frame.to_string()))
        .await
        .unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), kaitlyn.next())
        .await
        .expect("recv within 2s")
        .expect("stream open")
        .expect("recv ok");
    let text = match received {
        WsMessage::Text(t) => t,
        other => panic!("expected text frame, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    // Server must have overridden `from` to the authenticated identity.
    assert_eq!(value["from"], "court");
}
