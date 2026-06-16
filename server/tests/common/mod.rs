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
    invites::preview_invite,
    routing::Routing,
    store::Store,
    ws::{ws_handler, AppState},
};
use littlelove_crypto::sig::{challenge_signing_input, invite_consume_signing_input};
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
    // Order matters: messages and room_members FK rooms; invites FK accounts.
    // Truncate the dependent tables first, then the parents, with CASCADE on
    // accounts and rooms to catch anything we missed.
    for table in [
        "TRUNCATE TABLE attachments",
        "TRUNCATE TABLE messages",
        "TRUNCATE TABLE room_members",
        "TRUNCATE TABLE rooms CASCADE",
        "TRUNCATE TABLE invites",
        "TRUNCATE TABLE accounts RESTART IDENTITY CASCADE",
    ] {
        sqlx::query(table)
            .execute(store.pool())
            .await
            .unwrap_or_else(|e| panic!("{table}: {e}"));
    }
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
        .route("/invites/:code/preview", post(preview_invite))
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
/// `x25519_pub` is filled with deterministic bytes derived from the username
/// so room peers have distinguishable x25519_pubs in the wire output.
pub async fn insert_account(store: &Store, username: &str, vk: &VerifyingKey) {
    let mut x = [0u8; 32];
    for (i, b) in username.bytes().enumerate().take(32) {
        x[i] = b;
    }
    sqlx::query("INSERT INTO accounts (username, ed25519_pub, x25519_pub) VALUES ($1, $2, $3)")
        .bind(username)
        .bind(vk.to_bytes().to_vec())
        .bind(x.to_vec())
        .execute(store.pool())
        .await
        .unwrap();
}

/// Seed two humans with no partner link set. Returns `(a_id, b_id)`.
pub async fn seed_two_humans(store: &Store) -> (i64, i64) {
    let pool = store.pool();
    let (a,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('court', $1, $2) RETURNING id",
    )
    .bind(vec![10u8; 32])
    .bind(vec![11u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();
    let (b,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('kaitlyn', $1, $2) RETURNING id",
    )
    .bind(vec![20u8; 32])
    .bind(vec![21u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();
    (a, b)
}

/// Seed three humans with no partner link set. Returns `(a_id, b_id, c_id)`.
pub async fn seed_three_humans(store: &Store) -> (i64, i64, i64) {
    let (a, b) = seed_two_humans(store).await;
    let (c,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('riley', $1, $2) RETURNING id",
    )
    .bind(vec![40u8; 32])
    .bind(vec![41u8; 32])
    .fetch_one(store.pool())
    .await
    .unwrap();
    (a, b, c)
}

/// Seed a shared room with three humans:
/// - `court` + `kaitlyn` (monogamy partners)
/// - `riley` (a third co-member, no partner link)
/// - a room with all 3 members.
///
/// Returns `(court_id, kaitlyn_id, riley_id, room_id)`.
pub async fn seed_trio_room(store: &Store) -> (i64, i64, i64, String) {
    let pool = store.pool();

    let (court_id,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('court', $1, $2) RETURNING id",
    )
    .bind(vec![10u8; 32])
    .bind(vec![11u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();

    let (kait_id,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('kaitlyn', $1, $2) RETURNING id",
    )
    .bind(vec![20u8; 32])
    .bind(vec![21u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();

    sqlx::query("UPDATE accounts SET partner_account_id = $1 WHERE id = $2")
        .bind(kait_id)
        .bind(court_id)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("UPDATE accounts SET partner_account_id = $1 WHERE id = $2")
        .bind(court_id)
        .bind(kait_id)
        .execute(pool)
        .await
        .unwrap();

    let (riley_id,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('riley', $1, $2) RETURNING id",
    )
    .bind(vec![30u8; 32])
    .bind(vec![31u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();

    let room_id = ulid::Ulid::new().to_string();
    sqlx::query("INSERT INTO rooms (id, name) VALUES ($1, '')")
        .bind(&room_id)
        .execute(pool)
        .await
        .unwrap();
    for who in [court_id, kait_id, riley_id] {
        sqlx::query("INSERT INTO room_members (room_id, account_id) VALUES ($1, $2)")
            .bind(&room_id)
            .bind(who)
            .execute(pool)
            .await
            .unwrap();
    }

    (court_id, kait_id, riley_id, room_id)
}

/// Sign the **domain-separated** ConsumeInvite input (spec §8.5.1) over the
/// canonical 32-byte token. Returns base64 of the signature.
pub fn sign_invite_consume_b64(sk: &SigningKey, canonical_token: &[u8]) -> String {
    let input = invite_consume_signing_input(canonical_token);
    let sig = sk.sign(&input).to_bytes();
    B64.encode(sig)
}

/// Read a single WS text frame as JSON. Panics if the next item is not text.
pub async fn next_frame(sock: &mut Ws) -> serde_json::Value {
    let next = tokio::time::timeout(std::time::Duration::from_secs(10), sock.next())
        .await
        .expect("timed out waiting for a frame (10s)")
        .expect("stream open")
        .expect("recv ok");
    let text = match next {
        WsMessage::Text(t) => t,
        other => panic!("expected text, got {other:?}"),
    };
    serde_json::from_str(&text).expect("valid JSON")
}

/// Consume the immediate post-Authenticated `Rooms` frame (which every
/// handshake_as session receives). Tests use this to skip past it before
/// awaiting handler-specific responses.
pub async fn drain_rooms(sock: &mut Ws) -> serde_json::Value {
    let v = next_frame(sock).await;
    assert_eq!(v["kind"], "Rooms", "expected initial Rooms frame, got {v}");
    v
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
