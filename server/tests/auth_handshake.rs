use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use futures::{SinkExt, StreamExt};
use littlelove_api::auth::challenge_signing_input;
use serial_test::file_serial;
use tokio_tungstenite::{connect_async, tungstenite::Message as WsMessage};

mod common;
use common::{fresh_store, handshake_as, insert_account, spawn_server};

#[tokio::test]
#[file_serial]
async fn handshake_succeeds_with_valid_signature() {
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    insert_account(&store, "court", &sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;
    // handshake_as panics if the server doesn't send Authenticated.
    let _sock = handshake_as(addr, "court", &sk).await;
}

async fn receive_close_code(
    sock: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> Option<u16> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(remaining, sock.next()).await {
            Ok(Some(Ok(WsMessage::Close(Some(cf))))) => return Some(u16::from(cf.code)),
            Ok(Some(Ok(WsMessage::Close(None)))) => return None,
            Ok(Some(Ok(_))) => continue, // ignore any pre-close frames
            Ok(Some(Err(_))) | Ok(None) | Err(_) => return None,
        }
    }
}

#[tokio::test]
#[file_serial]
async fn handshake_fails_with_wrong_signature() {
    let store = fresh_store().await;
    let real_sk = SigningKey::from_bytes(&[7u8; 32]);
    let attacker_sk = SigningKey::from_bytes(&[8u8; 32]);
    insert_account(&store, "court", &real_sk.verifying_key()).await;

    let addr = spawn_server(Some(store)).await;
    let url = format!("ws://{addr}/ws");
    let (mut sock, _) = connect_async(url).await.unwrap();

    let challenge_text = match sock.next().await.unwrap().unwrap() {
        WsMessage::Text(t) => t,
        other => panic!("expected Challenge text, got {other:?}"),
    };
    let challenge: serde_json::Value = serde_json::from_str(&challenge_text).unwrap();
    let nonce = B64.decode(challenge["nonce"].as_str().unwrap()).unwrap();

    // Sign with the attacker's key, claim to be court. Use the domain-separated
    // input (spec §8.5.1) so the only thing wrong is the key, not the prefix.
    let sig = attacker_sk
        .sign(&challenge_signing_input(&nonce))
        .to_bytes();
    let identify = serde_json::json!({
        "kind": "Identify",
        "username": "court",
        "signature": B64.encode(sig),
    });
    sock.send(WsMessage::Text(identify.to_string()))
        .await
        .unwrap();

    let code = receive_close_code(&mut sock).await;
    assert_eq!(code, Some(4001), "expected close 4001, got {code:?}");
}

#[tokio::test]
#[file_serial]
async fn handshake_fails_for_unknown_username() {
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[9u8; 32]);
    // Do NOT insert the account.

    let addr = spawn_server(Some(store)).await;
    let url = format!("ws://{addr}/ws");
    let (mut sock, _) = connect_async(url).await.unwrap();

    let challenge_text = match sock.next().await.unwrap().unwrap() {
        WsMessage::Text(t) => t,
        other => panic!("expected Challenge text, got {other:?}"),
    };
    let challenge: serde_json::Value = serde_json::from_str(&challenge_text).unwrap();
    let nonce = B64.decode(challenge["nonce"].as_str().unwrap()).unwrap();

    let sig = sk.sign(&challenge_signing_input(&nonce)).to_bytes();
    let identify = serde_json::json!({
        "kind": "Identify",
        "username": "ghost",
        "signature": B64.encode(sig),
    });
    sock.send(WsMessage::Text(identify.to_string()))
        .await
        .unwrap();

    let code = receive_close_code(&mut sock).await;
    assert_eq!(code, Some(4001));
}

#[tokio::test]
#[file_serial]
async fn handshake_nonce_is_single_use_per_connection() {
    // Open two separate connections to the same account. The server must
    // issue a fresh nonce on each connection — verified by checking that
    // the two nonces differ, and that signing connection A's nonce can't
    // be reused on connection B.
    let store = fresh_store().await;
    let sk = SigningKey::from_bytes(&[11u8; 32]);
    insert_account(&store, "court", &sk.verifying_key()).await;
    let addr = spawn_server(Some(store)).await;

    async fn read_nonce(
        sock: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> Vec<u8> {
        let challenge_text = match sock.next().await.unwrap().unwrap() {
            WsMessage::Text(t) => t,
            other => panic!("expected Challenge text, got {other:?}"),
        };
        let challenge: serde_json::Value = serde_json::from_str(&challenge_text).unwrap();
        B64.decode(challenge["nonce"].as_str().unwrap()).unwrap()
    }

    let url = format!("ws://{addr}/ws");
    let (mut a, _) = connect_async(&url).await.unwrap();
    let nonce_a = read_nonce(&mut a).await;
    let (mut b, _) = connect_async(&url).await.unwrap();
    let nonce_b = read_nonce(&mut b).await;
    assert_ne!(
        nonce_a, nonce_b,
        "server must issue a fresh nonce per connection"
    );

    // Re-use connection A's signature on connection B → must fail.
    let sig_for_a = sk.sign(&challenge_signing_input(&nonce_a)).to_bytes();
    let replayed_identify = serde_json::json!({
        "kind": "Identify",
        "username": "court",
        "signature": B64.encode(sig_for_a),
    });
    b.send(WsMessage::Text(replayed_identify.to_string()))
        .await
        .unwrap();
    let code = receive_close_code(&mut b).await;
    assert_eq!(code, Some(4001), "replayed signature must be rejected");
}
