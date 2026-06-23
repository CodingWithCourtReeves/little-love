//! Integration: a PublishProfile frame is persisted and relayed to the linked
//! partner as a Profile frame, and a fresh connection replays the partner's
//! latest stored profile on connect.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server, Ws,
};

/// court + kaitlyn linked as partners with a shared room; both handshaked.
async fn paired_pair(
    store: &littlelove_api::store::Store,
    addr: std::net::SocketAddr,
    court_sk: &SigningKey,
    kait_sk: &SigningKey,
) -> (Ws, Ws) {
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
    let mut court = handshake_as(addr, "court", court_sk).await;
    drain_rooms(&mut court).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    (court, kaitlyn)
}

#[file_serial(db)]
#[tokio::test]
async fn publish_profile_relays_to_partner_and_persists() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    // Court publishes a profile (envelope is opaque base64 to the server).
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "PublishProfile",
                "envelope": "ZW52", // base64("env")
                "avatar_key": null,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    // Kaitlyn receives a Profile frame naming court.
    let frame = next_frame(&mut kaitlyn).await;
    assert_eq!(frame["kind"], "Profile", "{frame}");
    assert_eq!(frame["user"], "court");
    assert_eq!(frame["envelope"], "ZW52");

    // Persisted: a fresh connection for kaitlyn replays court's latest profile
    // on connect (after the initial Rooms frame; Presence is skipped as noise).
    let mut kaitlyn2 = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn2).await;
    let onconnect = next_frame(&mut kaitlyn2).await;
    assert_eq!(onconnect["kind"], "Profile", "{onconnect}");
    assert_eq!(onconnect["user"], "court");
    assert_eq!(onconnect["envelope"], "ZW52");
}
