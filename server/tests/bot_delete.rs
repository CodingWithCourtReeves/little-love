//! DELETE /accounts/bot/{label} under the v0.3 challenge-nonce protocol.
//! Flow: (1) POST .../delete-challenge → server issues nonce; (2) DELETE
//! with signature over (label, nonce). Captured signatures cannot replay
//! because the challenge row is consumed atomically with the verify.

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
    let r = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 201);
}

/// Request a delete-challenge and return the issued nonce as raw bytes.
async fn fetch_nonce(addr: std::net::SocketAddr, owner: &str, label: &str) -> Vec<u8> {
    let resp = reqwest::Client::new()
        .post(format!(
            "http://{addr}/accounts/bot/{label}/delete-challenge"
        ))
        .header("X-Owner-Username", owner)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200, "challenge request failed");
    let j: serde_json::Value = resp.json().await.unwrap();
    B64.decode(j["nonce"].as_str().unwrap()).unwrap()
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
    let nonce = fetch_nonce(addr, "court", "garden").await;

    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"garden", &nonce))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .header("X-Delete-Nonce", B64.encode(&nonce))
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

    // Challenge row was consumed by the successful DELETE.
    let (challenge_rows,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM bot_delete_challenges")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(challenge_rows, 0);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_rejects_wrong_signature() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;
    let nonce = fetch_nonce(addr, "court", "garden").await;

    let stranger = common::signing_key_from_seed([0xCC; 32]);
    let sig = stranger
        .sign(&bot_delete_signing_input(b"garden", &nonce))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .header("X-Delete-Nonce", B64.encode(&nonce))
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

    // Challenge endpoint is intentionally enumeration-blind: it issues a
    // nonce even when no bot with that label exists.
    let nonce = fetch_nonce(addr, "court", "nope").await;

    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"nope", &nonce))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/nope"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .header("X-Delete-Nonce", B64.encode(&nonce))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_rejects_missing_nonce_header() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;
    let nonce = fetch_nonce(addr, "court", "garden").await;
    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"garden", &nonce))
        .to_bytes();
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
async fn delete_bot_rejects_replayed_signature() {
    // The core property: a captured (signature, nonce) pair must not work
    // a second time even within the TTL window.
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;
    let nonce = fetch_nonce(addr, "court", "garden").await;
    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"garden", &nonce))
        .to_bytes();
    let sig_b64 = B64.encode(sig);
    let nonce_b64 = B64.encode(&nonce);

    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", &sig_b64)
        .header("X-Delete-Nonce", &nonce_b64)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 204);

    // Re-register the bot so the second DELETE would have succeeded under
    // the old (replay-vulnerable) protocol. With the challenge consumed,
    // the captured pair must now fail with 401.
    register_bot(addr, &owner_sk).await;
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", &sig_b64)
        .header("X-Delete-Nonce", &nonce_b64)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_bot_rejects_expired_nonce() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let pool = store.pool().clone();
    let addr = common::spawn_server(Some(store)).await;

    register_bot(addr, &owner_sk).await;
    let nonce = fetch_nonce(addr, "court", "garden").await;

    sqlx::query("UPDATE bot_delete_challenges SET expires_at = NOW() - INTERVAL '1 second'")
        .execute(&pool)
        .await
        .unwrap();

    let sig = owner_sk
        .sign(&bot_delete_signing_input(b"garden", &nonce))
        .to_bytes();
    let resp = reqwest::Client::new()
        .delete(format!("http://{addr}/accounts/bot/garden"))
        .header("X-Owner-Username", "court")
        .header("X-Owner-Signature", B64.encode(sig))
        .header("X-Delete-Nonce", B64.encode(&nonce))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);
}

#[tokio::test]
#[serial_test::serial]
async fn delete_challenge_returns_fresh_nonce_each_call() {
    let store = common::fresh_store().await;
    let owner_sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(&store, "court", &owner_sk.verifying_key()).await;
    let addr = common::spawn_server(Some(store)).await;

    let n1 = fetch_nonce(addr, "court", "garden").await;
    let n2 = fetch_nonce(addr, "court", "garden").await;
    assert_ne!(n1, n2, "challenge endpoint must rotate the nonce");
}
