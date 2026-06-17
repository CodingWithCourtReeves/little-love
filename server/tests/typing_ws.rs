//! Integration: a Typing frame from one partner is relayed to the other as a
//! transient Typing frame (carrying the sender's username), and never stored.

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
async fn typing_relays_to_partner_with_sender_username() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    // Court starts typing; kaitlyn receives the relayed presence.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Typing",
                "room_id": room_id,
                "typing": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let frame = next_frame(&mut kaitlyn).await;
    assert_eq!(frame["kind"], "Typing", "{frame}");
    assert_eq!(frame["room_id"], room_id);
    assert_eq!(frame["from"], "court");
    assert_eq!(frame["typing"], true);

    // Court stops; kaitlyn receives typing:false.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Typing",
                "room_id": room_id,
                "typing": false,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    let stop = next_frame(&mut kaitlyn).await;
    assert_eq!(stop["kind"], "Typing", "{stop}");
    assert_eq!(stop["typing"], false);

    // Nothing was persisted: a fresh Subscribe replays no Typing frames. After
    // subscribing, the only frame kaitlyn should see is one we trigger — assert
    // the typing relay left no stored rows by checking the message table.
    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM messages WHERE room_id = $1")
        .bind(&room_id)
        .fetch_one(store.pool())
        .await
        .unwrap();
    assert_eq!(count.0, 0, "typing must not be persisted as a message");
}

/// A Typing frame for a room the sender doesn't belong to is silently ignored
/// (no relay, no error) — best-effort presence.
#[file_serial(db)]
#[tokio::test]
async fn typing_for_non_member_room_is_ignored() {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let addr = spawn_server(Some(store.clone())).await;

    let (mut court, mut kaitlyn, room_id) = paired_pair(&store, addr, &court_sk, &kait_sk).await;

    // A bogus Typing for a room court isn't in: must NOT relay to kaitlyn.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Typing",
                "room_id": "01JNOTAROOM",
                "typing": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();
    // Immediately follow with a valid Typing into the real room. If the bogus
    // frame had been relayed, kaitlyn would receive it first; instead the next
    // (and only) frame she sees is the valid one for the real room.
    court
        .send(WsMessage::Text(
            serde_json::json!({
                "kind": "Typing",
                "room_id": room_id,
                "typing": true,
            })
            .to_string(),
        ))
        .await
        .unwrap();

    let frame = next_frame(&mut kaitlyn).await;
    assert_eq!(frame["kind"], "Typing", "{frame}");
    assert_eq!(
        frame["room_id"], room_id,
        "the bogus non-member frame must have been dropped, not relayed"
    );
}
