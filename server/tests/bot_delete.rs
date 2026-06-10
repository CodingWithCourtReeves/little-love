//! DELETE /accounts/bot/{label} with owner-signed delete (spec §8.5.1).

mod common;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::Signer;
use littlelove_crypto::sig::{bot_delete_signing_input, bot_register_signing_input};
use serde_json::json;

async fn register_bot(addr: std::net::SocketAddr, owner_sk: &ed25519_dalek::SigningKey) {
    let bot_ed = [0xBBu8; 32];
    let mut bot_x = [0u8; 32];
    for (i, b) in bot_x.iter_mut().enumerate() {
        *b = 0xCC ^ (i as u8);
    }
    let sig = owner_sk
        .sign(&bot_register_signing_input(&bot_ed))
        .to_bytes();
    let body = json!({
        "owner_username":  "court",
        "bot_label":       "garden",
        "bot_username":    "court-garden",
        "bot_ed25519_pub": B64.encode(bot_ed),
        "bot_x25519_pub":  B64.encode(bot_x),
        "owner_signature": B64.encode(sig),
    });
    let r = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_removes_account() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let pool = store.pool().clone();
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;

    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"garden"))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 204);

    let (count,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM accounts WHERE username = 'court-garden'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_rejects_wrong_signature() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;

    let stranger = common::signing_key_from_seed([0xCC; 32]);
    let sig = stranger.sign(&bot_delete_signing_input(b"garden")).to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_returns_404_when_label_unknown() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"nope"))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/nope"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}
