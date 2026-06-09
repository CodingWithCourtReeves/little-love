use std::time::Duration;

use chrono::Utc;
use ed25519_dalek::SigningKey;
use futures::{SinkExt, StreamExt};
use littlelove_api::store::MessageRow;
use serial_test::serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use uuid::Uuid;

mod common;
use common::{fresh_store, handshake_as, insert_account, spawn_server};

#[tokio::test]
#[serial]
async fn stores_and_replays_history_for_disconnected_recipient() {
    let store = fresh_store().await;
    let kaitlyn_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "kaitlyn", &kaitlyn_sk.verifying_key()).await;

    // Seed a stored message addressed to kaitlyn.
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "hey love".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();

    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "kaitlyn", &kaitlyn_sk).await;

    sock.send(WsMessage::Text(
        serde_json::json!({
            "type": "hello",
            "since": (Utc::now() - chrono::Duration::days(1)).to_rfc3339()
        })
        .to_string(),
    ))
    .await
    .unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), sock.next())
        .await
        .expect("recv within 2s")
        .expect("stream open")
        .expect("recv ok");
    let text = match received {
        WsMessage::Text(t) => t,
        other => panic!("expected text, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["body"], "hey love");
    assert_eq!(value["replayed"], true);
}
