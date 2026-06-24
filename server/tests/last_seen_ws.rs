//! Integration: the server stamps `last_seen` and delivers it on the Presence
//! frame — present (RFC3339) when the partner is offline, omitted when online.

use ed25519_dalek::SigningKey;
use futures::StreamExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{drain_rooms, fresh_store, handshake_as, insert_account, spawn_server, Ws};

/// court + kaitlyn linked as partners with a shared room.
async fn pair(store: &littlelove_api::store::Store) -> (i64, i64) {
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
    littlelove_api::rooms::create_room_with_members(pool, court_id, Some(kait_id), String::new())
        .await
        .unwrap();
    (court_id, kait_id)
}

/// Read frames until a `Presence` naming `user` arrives (skipping Rooms /
/// Profile / heartbeats). Unlike `common::next_frame`, this does NOT drop
/// Presence frames — they are what we're testing.
async fn next_presence_for(sock: &mut Ws, user: &str) -> serde_json::Value {
    loop {
        let next = tokio::time::timeout(std::time::Duration::from_secs(10), sock.next())
            .await
            .expect("timed out waiting for a Presence frame (10s)")
            .expect("stream open")
            .expect("recv ok");
        let text = match next {
            WsMessage::Text(t) => t,
            WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
            WsMessage::Close(_) => panic!("socket closed before Presence arrived"),
            other => panic!("expected text, got {other:?}"),
        };
        let v: serde_json::Value = serde_json::from_str(&text).expect("valid JSON");
        if v["kind"] == "Presence" && v["user"] == user {
            return v;
        }
    }
}

#[file_serial(db)]
#[tokio::test]
async fn offline_partner_presence_includes_last_seen() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let (court_id, _) = pair(&store).await;

    // Simulate court having had a session that ended (offline, with a last-seen).
    littlelove_api::accounts::touch_last_seen(store.pool(), court_id)
        .await
        .unwrap();

    let addr = spawn_server(Some(store.clone())).await;

    // Kaitlyn connects; her on-connect Presence for court must say offline and
    // carry court's last-seen.
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let presence = next_presence_for(&mut kaitlyn, "court").await;
    assert_eq!(presence["online"], false, "{presence}");
    assert!(
        presence["last_seen"].is_string(),
        "offline partner presence must carry last_seen: {presence}"
    );
}

#[file_serial(db)]
#[tokio::test]
async fn online_partner_presence_has_no_last_seen() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    pair(&store).await;
    let addr = spawn_server(Some(store.clone())).await;

    // Court online and staying connected.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;

    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    let presence = next_presence_for(&mut kaitlyn, "court").await;
    assert_eq!(presence["online"], true, "{presence}");
    assert!(
        presence.get("last_seen").is_none() || presence["last_seen"].is_null(),
        "online presence must omit last_seen: {presence}"
    );
}

#[file_serial(db)]
#[tokio::test]
async fn disconnect_broadcasts_last_seen_to_partner() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    pair(&store).await;
    let addr = spawn_server(Some(store.clone())).await;

    // Both online.
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn).await;

    // Court's connect announced online to kaitlyn; consume that first.
    let on = next_presence_for(&mut kaitlyn, "court").await;
    assert_eq!(on["online"], true, "{on}");

    // Court disconnects → kaitlyn gets an offline Presence carrying last_seen.
    court.close(None).await.unwrap();
    let off = next_presence_for(&mut kaitlyn, "court").await;
    assert_eq!(off["online"], false, "{off}");
    assert!(
        off["last_seen"].is_string(),
        "disconnect Presence must carry last_seen: {off}"
    );
}
