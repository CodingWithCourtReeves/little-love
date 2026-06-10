//! Spin up a tiny axum WebSocket server that issues a Challenge,
//! verifies the signature using littlelove-crypto, and replies
//! Authenticated. The bot side performs the handshake using its own
//! signing key.

use std::net::SocketAddr;

use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    response::IntoResponse,
    routing::any,
    Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use littlelove_bot::ws_client::{connect_and_identify, ClientIdentity};
use littlelove_crypto::sig::verify_signature;
use serde_json::Value;
use tokio::net::TcpListener;

async fn challenger(mut sock: WebSocket, expected_pub: [u8; 32]) {
    let nonce = [0xABu8; 32];
    let challenge = serde_json::json!({ "kind": "Challenge", "nonce": B64.encode(nonce) });
    sock.send(Message::Text(challenge.to_string()))
        .await
        .unwrap();

    let raw = match sock.recv().await.unwrap().unwrap() {
        Message::Text(t) => t,
        _ => panic!("non-text frame"),
    };
    let v: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(v["kind"], "Identify");
    let sig = B64.decode(v["signature"].as_str().unwrap()).unwrap();
    verify_signature(&expected_pub, &nonce, &sig).expect("server-side verify");

    sock.send(Message::Text(r#"{"kind":"Authenticated"}"#.into()))
        .await
        .unwrap();
    // Send an empty Rooms frame to satisfy the post-Authenticated push.
    sock.send(Message::Text(r#"{"kind":"Rooms","rooms":[]}"#.into()))
        .await
        .unwrap();
}

#[tokio::test]
async fn handshake_round_trips() {
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    let sk = SigningKey::generate(&mut OsRng);
    let pk = sk.verifying_key().to_bytes();

    let pk_for_handler = pk;
    let app = Router::new().route(
        "/connect",
        any(move |ws: WebSocketUpgrade| async move {
            ws.on_upgrade(move |sock| challenger(sock, pk_for_handler))
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let ws_url = format!("ws://{addr}/connect");
    let identity = ClientIdentity {
        username: "court_familiar".into(),
        ed25519_signing: sk,
    };
    let session = connect_and_identify(&ws_url, &identity)
        .await
        .expect("identify");
    assert!(session.initial_rooms.is_empty());
}

// Silence unused-import lint while keeping the trait in scope for IntoResponse.
#[allow(dead_code)]
fn _typecheck_into_response<T: IntoResponse>(_: T) {}
