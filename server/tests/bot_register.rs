//! POST /accounts/bot with owner-signed registration (spec §8.5.1).

mod common;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use littlelove_crypto::sig::bot_register_signing_input;
use serde_json::json;

async fn create_owner(store: &littlelove_api::store::Store, username: &str) -> SigningKey {
    let sk = common::signing_key_from_seed([0xAA; 32]);
    common::insert_account(store, username, &sk.verifying_key()).await;
    sk
}

fn bot_keys(seed: u8) -> ([u8; 32], [u8; 32]) {
    let ed = [seed; 32];
    let mut x = [0u8; 32];
    for (i, b) in x.iter_mut().enumerate() {
        *b = seed.wrapping_add(i as u8);
    }
    (ed, x)
}

#[tokio::test]
#[serial_test::serial]
async fn post_accounts_bot_creates_a_familiar_account() {
    let store = common::fresh_store().await;
    let owner_sk = create_owner(&store, "court").await;
    let addr = common::spawn_server(Some(store)).await;

    let (bot_ed, bot_x) = bot_keys(0xBB);
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
    let resp = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 201);
    let j: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(j["bot_username"], "court-garden");
    assert_eq!(j["is_bot"], true);
    assert!(j["account_id"].as_i64().is_some());
}

#[tokio::test]
#[serial_test::serial]
async fn post_accounts_bot_rejects_wrong_owner_signature() {
    let store = common::fresh_store().await;
    let _owner_sk = create_owner(&store, "court").await;
    let addr = common::spawn_server(Some(store)).await;

    let stranger = common::signing_key_from_seed([0xCC; 32]);
    let (bot_ed, bot_x) = bot_keys(0xDD);
    let sig = stranger
        .sign(&bot_register_signing_input(&bot_ed))
        .to_bytes();

    let body = json!({
        "owner_username":  "court",
        "bot_label":       "rogue",
        "bot_username":    "court-rogue",
        "bot_ed25519_pub": B64.encode(bot_ed),
        "bot_x25519_pub":  B64.encode(bot_x),
        "owner_signature": B64.encode(sig),
    });
    let resp = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);
}

#[tokio::test]
#[serial_test::serial]
async fn post_accounts_bot_idempotent_on_same_label() {
    let store = common::fresh_store().await;
    let owner_sk = create_owner(&store, "court").await;
    let addr = common::spawn_server(Some(store)).await;

    let (bot_ed, bot_x) = bot_keys(0xEE);
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

    let r1 = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(r1.status(), 201);

    let r2 = reqwest::Client::new()
        .post(format!("http://{addr}/accounts/bot"))
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(r2.status(), 200);
}
