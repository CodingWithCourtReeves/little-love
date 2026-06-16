//! Spec §8.2 amendment (2026-06-10): the post-Authenticated `Rooms` frame
//! carries an `owned_bots: Vec<Member>` array listing every familiar the
//! authenticated user owns. The Create-Chat picker reads this to surface
//! familiars that aren't yet members of any room.

use ed25519_dalek::SigningKey;
use serial_test::file_serial;

mod common;
use common::{fresh_store, handshake_as, insert_account, next_frame, spawn_server};

#[tokio::test]
#[file_serial(db)]
async fn rooms_frame_includes_owned_bots_owned_by_authenticated_user() {
    let store = fresh_store().await;

    // Two humans, each with their own familiar. Neither bot is in any room.
    let court_sk = SigningKey::from_bytes(&[31u8; 32]);
    insert_account(&store, "court", &court_sk.verifying_key()).await;
    let kait_sk = SigningKey::from_bytes(&[32u8; 32]);
    insert_account(&store, "kaitlyn", &kait_sk.verifying_key()).await;

    let court_id: i64 = sqlx::query_scalar("SELECT id FROM accounts WHERE username = 'court'")
        .fetch_one(store.pool())
        .await
        .unwrap();
    let kait_id: i64 = sqlx::query_scalar("SELECT id FROM accounts WHERE username = 'kaitlyn'")
        .fetch_one(store.pool())
        .await
        .unwrap();

    sqlx::query(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub, is_bot, owner_account_id)
         VALUES ('court-garden', $1, $2, TRUE, $3)",
    )
    .bind(vec![60u8; 32])
    .bind(vec![61u8; 32])
    .bind(court_id)
    .execute(store.pool())
    .await
    .unwrap();

    sqlx::query(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub, is_bot, owner_account_id)
         VALUES ('kaitlyn-journal', $1, $2, TRUE, $3)",
    )
    .bind(vec![70u8; 32])
    .bind(vec![71u8; 32])
    .bind(kait_id)
    .execute(store.pool())
    .await
    .unwrap();

    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "court", &court_sk).await;
    let v = next_frame(&mut sock).await;

    assert_eq!(v["kind"], "Rooms", "expected initial Rooms frame, got {v}");
    assert_eq!(v["rooms"].as_array().unwrap().len(), 0, "no rooms yet");

    let owned = v["owned_bots"]
        .as_array()
        .expect("owned_bots field present and array");
    assert_eq!(owned.len(), 1, "court owns exactly one familiar: {v}");

    let bot = &owned[0];
    assert_eq!(bot["username"], "court-garden");
    assert_eq!(bot["is_bot"], true);
    assert_eq!(bot["owner_username"], "court");
}

#[tokio::test]
#[file_serial(db)]
async fn rooms_frame_owned_bots_empty_when_user_owns_no_familiars() {
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[33u8; 32]);
    insert_account(&store, "lonely", &sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;
    let mut sock = handshake_as(addr, "lonely", &sk).await;
    let v = next_frame(&mut sock).await;

    assert_eq!(v["kind"], "Rooms");
    let owned = v["owned_bots"]
        .as_array()
        .expect("owned_bots field present and array even when empty");
    assert!(owned.is_empty(), "no familiars → empty array: {v}");
}
