//! POST /invites/{code}/preview returns the full room roster (spec §8.1 v0.3).

mod common;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::Signer;
use littlelove_crypto::sig::bot_register_signing_input;
use serde_json::json;

#[tokio::test]
#[serial_test::serial]
async fn invite_preview_returns_room_roster_including_bots() {
    let store = common::fresh_store().await;

    // Owner (court) + bot familiar (court-garden).
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let pool = store.pool().clone();
    let addr = common::spawn_server(Some(store)).await;

    let bot_ed = [0xBBu8; 32];
    let mut bot_x = [0u8; 32];
    for (i, b) in bot_x.iter_mut().enumerate() {
        *b = 0xCC ^ (i as u8);
    }
    let sig = owner_sk
        .sign(&bot_register_signing_input(&bot_ed, &bot_x))
        .to_bytes();
    let body = json!({
        "owner_username":  "court",
        "bot_label":       "garden",
        "bot_username":    "court-garden",
        "bot_ed25519_pub": B64.encode(bot_ed),
        "bot_x25519_pub":  B64.encode(bot_x),
        "owner_signature": B64.encode(sig),
    });
    let bot_resp = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(bot_resp.status(), 201);
    let bot_j: serde_json::Value = bot_resp.json().await.unwrap();
    let bot_id = bot_j["account_id"].as_i64().unwrap();

    // Seed a room with the bot + an invite tied to that room.
    let (court_id,): (i64,) = sqlx::query_as("SELECT id FROM accounts WHERE username = 'court'")
        .fetch_one(&pool)
        .await
        .unwrap();
    let room_id = littlelove_api::rooms::create_room_with_members(
        &pool,
        court_id,
        None,
        &[bot_id],
        "Travel".into(),
    )
    .await
    .unwrap();

    let (canonical, code, hash) = littlelove_crypto::invite::generate_invite();
    let expires_at = littlelove_api::invites::default_expiry(chrono::Utc::now());
    littlelove_api::invites::create_invite_record(
        &pool,
        court_id,
        &hash,
        expires_at,
        Some(&room_id),
    )
    .await
    .unwrap();
    let _ = canonical;

    let resp: serde_json::Value = reqwest::Client::new()
        .post(format!("http://{addr}/invites/{code}/preview"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(resp["room_id"].as_str().unwrap(), room_id);
    assert_eq!(resp["name"], "Travel");
    let members = resp["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    let usernames: Vec<&str> = members
        .iter()
        .map(|m| m["username"].as_str().unwrap())
        .collect();
    assert!(usernames.contains(&"court"));
    assert!(usernames.contains(&"court-garden"));
}
