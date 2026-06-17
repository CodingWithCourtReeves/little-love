//! End-to-end: a content-free push fires for the recipient only when they have
//! no live WS session. Uses a fake PushSender (no network).

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server_with_push, Ws,
};

use littlelove_api::push::{PushMessage, PushSender, SendOutcome};
use littlelove_api::push_tokens::upsert_token;

struct FakeSender {
    calls: mpsc::UnboundedSender<PushMessage>,
}

#[async_trait::async_trait]
impl PushSender for FakeSender {
    async fn send(&self, msg: &PushMessage) -> SendOutcome {
        let _ = self.calls.send(msg.clone());
        SendOutcome::Delivered
    }
}

fn x25519_b64(username: &str) -> String {
    let mut x = [0u8; 32];
    for (i, b) in username.bytes().enumerate().take(32) {
        x[i] = b;
    }
    B64.encode(x)
}

/// court sends one message (self-copy + kaitlyn copy) via a real Send frame and
/// drains court's own live self-echo. Does NOT read any recipient frame, so it
/// works whether or not kaitlyn is online.
async fn court_sends(court: &mut Ws, room_id: &str) {
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
    let self_echo = next_frame(court).await;
    assert_eq!(self_echo["body"], "ct_for_self", "{self_echo}");
}

#[file_serial(db)]
#[tokio::test]
async fn push_fires_when_recipient_offline_not_when_online() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;

    let (court_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'court'")
        .fetch_one(store.pool())
        .await
        .unwrap();
    let (kait_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'kaitlyn'")
        .fetch_one(store.pool())
        .await
        .unwrap();
    littlelove_api::rooms::set_partner_link(store.pool(), court_id, kait_id)
        .await
        .unwrap();
    let room_id = littlelove_api::rooms::create_room_with_members(
        store.pool(),
        court_id,
        Some(kait_id),
        String::new(),
    )
    .await
    .unwrap();

    // Kaitlyn has a registered device token.
    upsert_token(store.pool(), kait_id, "kait-dev", "kaitTOKEN", "sandbox")
        .await
        .unwrap();

    let (tx, mut rx) = mpsc::unbounded_channel::<PushMessage>();
    let fake: Arc<dyn PushSender> = Arc::new(FakeSender { calls: tx });
    let addr = spawn_server_with_push(Some(store.clone()), Some(fake)).await;

    // court connects and sends while kaitlyn is OFFLINE.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    court_sends(&mut court, &room_id).await;

    // The push should have fired for kaitlyn (offline → 0 sessions delivered).
    let got = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
        .await
        .expect("a push should fire for the offline recipient")
        .unwrap();
    assert_eq!(got.token, "kaitTOKEN");
    assert_eq!(got.room_id, room_id);
    assert_eq!(got.environment, "sandbox");

    // Now kaitlyn comes ONLINE; a second send must NOT push (she's a live
    // session, so routing.deliver reaches her in-app).
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn).await;

    court_sends(&mut court, &room_id).await;
    // kaitlyn receives the message live.
    let to_kait = next_frame(&mut kaitlyn).await;
    assert_eq!(to_kait["body"], "ct_for_kait", "{to_kait}");

    // No push within a short window.
    let none = tokio::time::timeout(std::time::Duration::from_millis(500), rx.recv()).await;
    assert!(none.is_err(), "online recipient must not get a push");
}
