//! Integration: DeleteRoom deletes a channel for both partners, and the
//! partner chat (the unnamed room) can be neither deleted nor named.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{
    drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server, Ws,
};
use littlelove_api::rooms::{create_room_with_members, room_detail, set_partner_link};
use littlelove_api::store::Store;

struct Couple {
    store: Store,
    court: Ws,
    kaitlyn: Ws,
    partner_room: String,
    channel: String,
    addr: std::net::SocketAddr,
}

/// court + kaitlyn as partners, with their unnamed partner chat and a
/// "Travel" channel; both handshaked with their Rooms frame drained.
async fn couple() -> Couple {
    let store = fresh_store().await;
    let court_sk = SigningKey::from_bytes(&[1u8; 32]);
    let kait_sk = SigningKey::from_bytes(&[2u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;
    let pool = store.pool();
    let id = |name: &'static str| async move {
        let (id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = $1")
            .bind(name)
            .fetch_one(pool)
            .await
            .unwrap();
        id
    };
    let (court_id, kait_id) = (id("court").await, id("kaitlyn").await);
    set_partner_link(pool, court_id, kait_id).await.unwrap();
    let partner_room = create_room_with_members(pool, court_id, Some(kait_id), String::new())
        .await
        .unwrap();
    let channel = create_room_with_members(pool, court_id, Some(kait_id), "Travel".into())
        .await
        .unwrap();
    let addr = spawn_server(Some(store.clone())).await;
    let mut court = handshake_as(addr, "court", &court_sk).await;
    drain_rooms(&mut court).await;
    let mut kaitlyn = handshake_as(addr, "kaitlyn", &kait_sk).await;
    drain_rooms(&mut kaitlyn).await;
    Couple {
        store,
        court,
        kaitlyn,
        partner_room,
        channel,
        addr,
    }
}

async fn send(sock: &mut Ws, frame: serde_json::Value) {
    sock.send(WsMessage::Text(frame.to_string())).await.unwrap();
}

async fn room_exists(store: &Store, room_id: &str) -> bool {
    room_detail(store.pool(), room_id).await.unwrap().is_some()
}

#[file_serial(db)]
#[tokio::test]
async fn delete_room_removes_channel_and_notifies_both_members() {
    let mut c = couple().await;
    send(
        &mut c.court,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.channel}),
    )
    .await;

    for sock in [&mut c.court, &mut c.kaitlyn] {
        let f = next_frame(sock).await;
        assert_eq!(f["kind"], "RoomDeleted", "{f}");
        assert_eq!(f["room_id"], c.channel);
        assert_eq!(f["deleted_by"], "court");
    }
    assert!(!room_exists(&c.store, &c.channel).await);
    assert!(room_exists(&c.store, &c.partner_room).await);
}

#[file_serial(db)]
#[tokio::test]
async fn delete_room_with_messages_succeeds() {
    let mut c = couple().await;
    sqlx::query(
        "INSERT INTO messages (id, room_id, from_account_id, recipient_account_id, body, ts)
         SELECT '01MSG', $1, a.id, b.id, 'ciphertext', now()
         FROM accounts a, accounts b WHERE a.username = 'court' AND b.username = 'kaitlyn'",
    )
    .bind(&c.channel)
    .execute(c.store.pool())
    .await
    .unwrap();

    send(
        &mut c.kaitlyn,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.channel}),
    )
    .await;

    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "RoomDeleted", "{f}");
    assert_eq!(f["deleted_by"], "kaitlyn");
    let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM messages WHERE room_id = $1")
        .bind(&c.channel)
        .fetch_one(c.store.pool())
        .await
        .unwrap();
    assert_eq!(n, 0);
}

#[file_serial(db)]
#[tokio::test]
async fn delete_room_for_non_member_is_unknown_room() {
    let c = couple().await;
    let riley_sk = SigningKey::from_bytes(&[3u8; 32]);
    insert_account(&c.store, "riley", &riley_sk.verifying_key()).await;
    let mut riley = handshake_as(c.addr, "riley", &riley_sk).await;
    drain_rooms(&mut riley).await;

    send(
        &mut riley,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.channel}),
    )
    .await;

    let f = next_frame(&mut riley).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "UnknownRoom");
    assert_eq!(f["room_id"], c.channel);
    assert!(room_exists(&c.store, &c.channel).await);
}

#[file_serial(db)]
#[tokio::test]
async fn delete_partner_chat_is_refused() {
    let mut c = couple().await;
    send(
        &mut c.court,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.partner_room}),
    )
    .await;

    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "PartnerChatLocked");
    assert_eq!(f["room_id"], c.partner_room);
    assert!(room_exists(&c.store, &c.partner_room).await);
}

#[file_serial(db)]
#[tokio::test]
async fn rename_partner_chat_is_refused() {
    let mut c = couple().await;
    send(
        &mut c.court,
        serde_json::json!({"kind": "RenameRoom", "room_id": c.partner_room, "name": "Ours"}),
    )
    .await;

    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "PartnerChatLocked");
    let detail = room_detail(c.store.pool(), &c.partner_room)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(detail.name, "");
}

#[file_serial(db)]
#[tokio::test]
async fn rename_channel_to_empty_is_refused() {
    let mut c = couple().await;
    send(
        &mut c.court,
        serde_json::json!({"kind": "RenameRoom", "room_id": c.channel, "name": "   "}),
    )
    .await;

    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "BadName");
    let detail = room_detail(c.store.pool(), &c.channel)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(detail.name, "Travel");
}

#[file_serial(db)]
#[tokio::test]
async fn create_room_with_empty_name_is_refused() {
    let mut c = couple().await;
    send(
        &mut c.court,
        serde_json::json!({"kind": "CreateRoom", "name": "", "invite_human_partner": true}),
    )
    .await;

    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "BadName");
}

#[file_serial(db)]
#[tokio::test]
async fn delete_room_flood_is_rate_limited() {
    let mut c = couple().await;
    for i in 0..5 {
        let id = format!("01NOPE{i}");
        send(
            &mut c.court,
            serde_json::json!({"kind": "DeleteRoom", "room_id": id}),
        )
        .await;
        let f = next_frame(&mut c.court).await;
        assert_eq!(f["code"], "UnknownRoom", "{f}");
    }
    send(
        &mut c.court,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.channel}),
    )
    .await;
    let f = next_frame(&mut c.court).await;
    assert_eq!(f["code"], "RateLimited", "{f}");
    assert_eq!(f["room_id"], c.channel);
    assert!(room_exists(&c.store, &c.channel).await);
}

/// An old build let the partner chat be renamed, so a couple can have only
/// named rooms. Deleting the last one would leave them with no room at all.
#[file_serial(db)]
#[tokio::test]
async fn deleting_the_last_shared_room_is_refused() {
    let mut c = couple().await;
    sqlx::query("UPDATE rooms SET name = 'Ours' WHERE id = $1")
        .bind(&c.partner_room)
        .execute(c.store.pool())
        .await
        .unwrap();

    // Travel isn't the last room: it goes.
    send(
        &mut c.court,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.channel}),
    )
    .await;
    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "RoomDeleted", "{f}");

    // "Ours" is now the last one: refused, and it stays.
    send(
        &mut c.court,
        serde_json::json!({"kind": "DeleteRoom", "room_id": c.partner_room}),
    )
    .await;
    let f = next_frame(&mut c.court).await;
    assert_eq!(f["kind"], "Error", "{f}");
    assert_eq!(f["code"], "PartnerChatLocked");
    assert_eq!(f["room_id"], c.partner_room);
    assert!(room_exists(&c.store, &c.partner_room).await);
}
