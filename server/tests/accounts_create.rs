use serial_test::file_serial;

mod common;
use common::{fresh_store, spawn_server};

#[tokio::test]
#[file_serial]
async fn post_accounts_creates_an_account() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let url = format!("http://{addr}/accounts");
    let body = serde_json::json!({
        "username": "court",
        "ed25519_pub": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "x25519_pub":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    });
    let resp = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 201);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["username"], "court");
    assert!(v.get("created_at").is_some());
}

#[tokio::test]
#[file_serial]
async fn post_accounts_returns_409_on_duplicate_username() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let url = format!("http://{addr}/accounts");
    let body = serde_json::json!({
        "username": "court",
        "ed25519_pub": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "x25519_pub":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    });
    let _ = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .unwrap();
    let resp = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 409);
}

#[tokio::test]
#[file_serial]
async fn post_accounts_returns_400_on_bad_username() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let url = format!("http://{addr}/accounts");
    let long = "a".repeat(21);
    for bad in ["ab", "Court", "co-urt", "court!", long.as_str()] {
        let body = serde_json::json!({
            "username": bad,
            "ed25519_pub": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "x25519_pub":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        });
        let resp = reqwest::Client::new()
            .post(&url)
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 400, "expected 400 for username {bad:?}");
    }
}

#[tokio::test]
#[file_serial]
async fn post_accounts_returns_400_on_bad_pubkey_length() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let url = format!("http://{addr}/accounts");
    let body = serde_json::json!({
        "username": "court",
        "ed25519_pub": "AAAA",  // 3 bytes, not 32
        "x25519_pub":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    });
    let resp = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 400);
}
