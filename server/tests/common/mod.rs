#![allow(dead_code)]

use std::net::SocketAddr;

use axum::{
    routing::{get, post},
    Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use futures::{SinkExt, StreamExt};
use littlelove_api::{
    accounts::{create_account, get_account_by_username},
    auth::challenge_signing_input,
    routing::Routing,
    store::Store,
    ws::{ws_handler, AppState},
};
use tokio::net::TcpListener;
use tokio_tungstenite::{
    connect_async, tungstenite::Message as WsMessage, MaybeTlsStream, WebSocketStream,
};

pub type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

pub fn db_url() -> String {
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set; run via dev-up")
}

pub async fn fresh_store() -> Store {
    let store = Store::connect(&db_url()).await.expect("connect");
    sqlx::query("TRUNCATE TABLE accounts RESTART IDENTITY CASCADE")
        .execute(store.pool())
        .await
        .expect("truncate accounts");
    sqlx::query("TRUNCATE TABLE messages")
        .execute(store.pool())
        .await
        .expect("truncate messages");
    store
}

pub fn build_app(store: Option<Store>) -> Router {
    let state = AppState {
        routing: Routing::new(),
        store,
    };
    Router::new()
        .route("/accounts", post(create_account))
        .route(
            "/accounts/by-username/:username",
            get(get_account_by_username),
        )
        .route("/ws", get(ws_handler))
        .with_state(state)
}

pub async fn spawn_server(store: Option<Store>) -> SocketAddr {
    let app = build_app(store);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    addr
}

pub fn signing_key_from_seed(seed: [u8; 32]) -> SigningKey {
    SigningKey::from_bytes(&seed)
}

pub fn ed_pub_b64(sk: &SigningKey) -> String {
    B64.encode(sk.verifying_key().to_bytes())
}

/// Sign the **domain-separated** Challenge input (spec §8.5.1) and return
/// the base64 of the signature. Tests must use this — signing the bare
/// nonce will produce a sig that the server rejects.
pub fn sign_nonce_b64(sk: &SigningKey, nonce: &[u8]) -> String {
    let input = challenge_signing_input(nonce);
    let sig = sk.sign(&input).to_bytes();
    B64.encode(sig)
}

/// Insert an account row directly via SQL (skips REST round-trip).
pub async fn insert_account(store: &Store, username: &str, vk: &VerifyingKey) {
    sqlx::query("INSERT INTO accounts (username, ed25519_pub, x25519_pub) VALUES ($1, $2, $3)")
        .bind(username)
        .bind(vk.to_bytes().to_vec())
        .bind(vec![0u8; 32]) // x25519 not exercised in WT-A
        .execute(store.pool())
        .await
        .unwrap();
}

/// Open a WS connection and complete the Challenge → Identify → Authenticated handshake.
pub async fn handshake_as(addr: SocketAddr, username: &str, sk: &SigningKey) -> Ws {
    let url = format!("ws://{addr}/ws");
    let (mut sock, _) = connect_async(url).await.unwrap();

    let challenge_text = match sock.next().await.unwrap().unwrap() {
        WsMessage::Text(t) => t,
        other => panic!("expected Challenge text, got {other:?}"),
    };
    let challenge: serde_json::Value = serde_json::from_str(&challenge_text).unwrap();
    assert_eq!(challenge["kind"], "Challenge");
    let nonce = B64.decode(challenge["nonce"].as_str().unwrap()).unwrap();

    let signature = sign_nonce_b64(sk, &nonce);
    let identify = serde_json::json!({
        "kind": "Identify",
        "username": username,
        "signature": signature,
    });
    sock.send(WsMessage::Text(identify.to_string()))
        .await
        .unwrap();

    let auth_text = match sock.next().await.unwrap().unwrap() {
        WsMessage::Text(t) => t,
        other => panic!("expected Authenticated, got {other:?}"),
    };
    let auth: serde_json::Value = serde_json::from_str(&auth_text).unwrap();
    assert_eq!(
        auth["kind"], "Authenticated",
        "handshake should succeed: {auth_text}"
    );

    sock
}
