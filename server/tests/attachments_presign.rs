//! Integration tests for the attachment presign handlers (RequestUpload /
//! RequestDownload). court + kaitlyn are a couple sharing a room; mallory is an
//! outsider with no room membership. Accounts are seeded with their real
//! derived Ed25519 pubkeys so the handshake signature verifies.

use ed25519_dalek::SigningKey;
use futures::SinkExt;
use serial_test::file_serial;
use tokio_tungstenite::tungstenite::Message as WsMessage;

mod common;
use common::{drain_rooms, fresh_store, handshake_as, insert_account, next_frame, spawn_server};

const COURT_SEED: [u8; 32] = [1u8; 32];
const KAIT_SEED: [u8; 32] = [2u8; 32];
const MALLORY_SEED: [u8; 32] = [9u8; 32];

/// Seed court + kaitlyn (couple + shared room) and mallory (outsider).
/// Returns the shared room_id.
async fn seed_couple_with_outsider(store: &littlelove_api::store::Store) -> String {
    let pool = store.pool();
    insert_account(store, "court", &SigningKey::from_bytes(&COURT_SEED).verifying_key()).await;
    insert_account(store, "kaitlyn", &SigningKey::from_bytes(&KAIT_SEED).verifying_key()).await;
    insert_account(store, "mallory", &SigningKey::from_bytes(&MALLORY_SEED).verifying_key()).await;

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
        .unwrap()
}

#[file_serial(db)]
#[tokio::test]
async fn member_gets_upload_granted_and_row_inserted() {
    let store = fresh_store().await;
    let room_id = seed_couple_with_outsider(&store).await;
    let addr = spawn_server(Some(store.clone())).await;
    let mut sock = handshake_as(addr, "court", &SigningKey::from_bytes(&COURT_SEED)).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 1_048_576,
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "UploadGranted", "got {v}");
    assert!(v["url"].as_str().unwrap().contains("X-Amz-Signature="));
    let blob_key = v["blob_key"].as_str().unwrap();

    let room: Option<(String,)> =
        sqlx::query_as("SELECT room_id FROM attachments WHERE blob_key = $1")
            .bind(blob_key)
            .fetch_optional(store.pool())
            .await
            .unwrap();
    assert_eq!(room.unwrap().0, room_id);
}

#[file_serial(db)]
#[tokio::test]
async fn oversize_upload_rejected() {
    let store = fresh_store().await;
    let room_id = seed_couple_with_outsider(&store).await;
    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "court", &SigningKey::from_bytes(&COURT_SEED)).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 600i64 * 1024 * 1024, // 600 MiB > 500 cap
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "BlobTooLarge");
}

#[file_serial(db)]
#[tokio::test]
async fn non_member_upload_rejected() {
    let store = fresh_store().await;
    let room_id = seed_couple_with_outsider(&store).await;
    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "mallory", &SigningKey::from_bytes(&MALLORY_SEED)).await;
    drain_rooms(&mut sock).await;

    let req = serde_json::json!({
        "kind":"RequestUpload",
        "request_id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "room_id": room_id,
        "byte_size": 1024,
    });
    sock.send(WsMessage::Text(req.to_string())).await.unwrap();
    let v = next_frame(&mut sock).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "UnknownRoom");
}

#[file_serial(db)]
#[tokio::test]
async fn cross_room_download_denied_member_allowed() {
    let store = fresh_store().await;
    let room_id = seed_couple_with_outsider(&store).await;
    // Seed a blob owned by court in the room.
    let court = littlelove_api::rooms::account_id_by_username(store.pool(), "court")
        .await
        .unwrap()
        .unwrap();
    littlelove_api::attachments::insert_attachment(store.pool(), "01JBLOB", &room_id, court, 1024)
        .await
        .unwrap();
    let addr = spawn_server(Some(store)).await;

    // mallory (non-member) → UnknownBlob
    let mut m = handshake_as(addr, "mallory", &SigningKey::from_bytes(&MALLORY_SEED)).await;
    drain_rooms(&mut m).await;
    m.send(WsMessage::Text(
        serde_json::json!({"kind":"RequestDownload","blob_key":"01JBLOB"}).to_string(),
    ))
    .await
    .unwrap();
    let v = next_frame(&mut m).await;
    assert_eq!(v["kind"], "Error");
    assert_eq!(v["code"], "UnknownBlob");

    // court (member) → DownloadGranted
    let mut c = handshake_as(addr, "court", &SigningKey::from_bytes(&COURT_SEED)).await;
    drain_rooms(&mut c).await;
    c.send(WsMessage::Text(
        serde_json::json!({"kind":"RequestDownload","blob_key":"01JBLOB"}).to_string(),
    ))
    .await
    .unwrap();
    let v = next_frame(&mut c).await;
    assert_eq!(v["kind"], "DownloadGranted", "got {v}");
    assert!(v["url"].as_str().unwrap().contains("X-Amz-Signature="));
}
