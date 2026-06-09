use serial_test::serial;

mod common;
use common::{fresh_store, spawn_server};

#[tokio::test]
#[serial]
async fn get_unknown_account_returns_404() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let url = format!("http://{addr}/accounts/by-username/court");
    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status(), 404);
}

#[tokio::test]
#[serial]
async fn get_known_account_returns_publics() {
    let store = fresh_store().await;
    let addr = spawn_server(Some(store)).await;
    let create_url = format!("http://{addr}/accounts");
    let body = serde_json::json!({
        "username": "court",
        "ed25519_pub": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "x25519_pub":  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    });
    reqwest::Client::new()
        .post(&create_url)
        .json(&body)
        .send()
        .await
        .unwrap();

    let url = format!("http://{addr}/accounts/by-username/court");
    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status(), 200);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["username"], "court");
    assert_eq!(v["ed25519_pub"], "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    assert_eq!(v["x25519_pub"], "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    assert!(v.get("created_at").is_some());
}
