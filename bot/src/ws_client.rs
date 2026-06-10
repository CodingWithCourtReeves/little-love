//! WSS Challenge → Identify → Authenticated handshake + frame I/O.
//!
//! Spec §3.3 + §8.2. The client uses `littlelove_crypto::sig` for
//! domain-separated signing; the verifier on the server side uses the
//! same crate.

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ed25519_dalek::{Signer, SigningKey};
use futures::{SinkExt, StreamExt};
use littlelove_crypto::sig::{challenge_signing_input, invite_consume_signing_input};
use serde::{Deserialize, Serialize};
use tokio_tungstenite::tungstenite::Message;

pub struct ClientIdentity {
    pub username: String,
    pub ed25519_signing: SigningKey,
}

pub struct Session {
    pub socket: WsStream,
    pub initial_rooms: Vec<RoomSummary>,
}

pub type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct RoomSummary {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum ServerFrame {
    Challenge {
        nonce: String,
    },
    Authenticated,
    Rooms {
        rooms: Vec<RoomSummary>,
    },
    Error {
        code: String,
        #[serde(default)]
        message: String,
    },
}

pub async fn connect_and_identify(ws_url: &str, identity: &ClientIdentity) -> Result<Session> {
    let (mut sock, _resp) = tokio_tungstenite::connect_async(ws_url)
        .await
        .with_context(|| format!("WSS connect {ws_url}"))?;

    let first = sock
        .next()
        .await
        .ok_or_else(|| anyhow!("server closed before Challenge"))??;
    let nonce_b64 = match first {
        Message::Text(t) => {
            let parsed: ServerFrame = serde_json::from_str(&t)?;
            match parsed {
                ServerFrame::Challenge { nonce } => nonce,
                ServerFrame::Error { code, message } => {
                    return Err(anyhow!("server error before Challenge: {code} {message}"));
                }
                _ => return Err(anyhow!("expected Challenge, got {t}")),
            }
        }
        other => return Err(anyhow!("expected Text Challenge, got {other:?}")),
    };
    let nonce = B64.decode(nonce_b64.as_bytes())?;
    let sig = identity
        .ed25519_signing
        .sign(&challenge_signing_input(&nonce));
    let identify = serde_json::json!({
        "kind": "Identify",
        "username": identity.username,
        "signature": B64.encode(sig.to_bytes()),
    });
    sock.send(Message::Text(identify.to_string())).await?;

    // Expect Authenticated, then Rooms.
    let initial_rooms = loop {
        let frame = sock
            .next()
            .await
            .ok_or_else(|| anyhow!("server closed mid-handshake"))??;
        let text = match frame {
            Message::Text(t) => t,
            Message::Close(c) => return Err(anyhow!("server closed: {c:?}")),
            other => return Err(anyhow!("non-text frame: {other:?}")),
        };
        let parsed: ServerFrame = serde_json::from_str(&text)?;
        match parsed {
            ServerFrame::Authenticated => continue,
            ServerFrame::Rooms { rooms } => break rooms,
            ServerFrame::Error { code, message } => {
                return Err(anyhow!("auth error: {code} {message}"));
            }
            ServerFrame::Challenge { .. } => {
                return Err(anyhow!("unexpected second Challenge"));
            }
        }
    };
    Ok(Session {
        socket: sock,
        initial_rooms,
    })
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct RoomDescriptor {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
#[allow(dead_code)]
enum RoomServerFrame {
    InviteConsumed(RoomDescriptor),
    RoomCreated(RoomDescriptor),
    Rooms {
        rooms: Vec<RoomSummary>,
    },
    Message {
        id: String,
        room_id: String,
        from: String,
        ts: chrono::DateTime<chrono::Utc>,
        body: String,
        #[serde(default)]
        replayed: bool,
    },
    Error {
        code: String,
        #[serde(default)]
        message: String,
    },
    InviteCreated {
        code: String,
        qr_png_base64: String,
        expires_at: chrono::DateTime<chrono::Utc>,
    },
}

pub async fn consume_invite(
    session: &mut Session,
    identity: &ClientIdentity,
    code: &str,
) -> Result<RoomDescriptor> {
    let canonical = littlelove_crypto::invite::decode_code(code)
        .map_err(|e| anyhow!("invalid invite code: {e}"))?;
    let sig = identity
        .ed25519_signing
        .sign(&invite_consume_signing_input(&canonical));
    let frame = serde_json::json!({
        "kind": "ConsumeInvite",
        "code": code,
        "signature_over_token": B64.encode(sig.to_bytes()),
    });
    session
        .socket
        .send(Message::Text(frame.to_string()))
        .await?;
    loop {
        let next = session
            .socket
            .next()
            .await
            .ok_or_else(|| anyhow!("server closed waiting for InviteConsumed"))??;
        if let Message::Text(t) = next {
            let parsed: RoomServerFrame = serde_json::from_str(&t)?;
            match parsed {
                RoomServerFrame::InviteConsumed(d) => return Ok(d),
                RoomServerFrame::Error { code, message } => {
                    return Err(anyhow!("consume invite error: {code} {message}"));
                }
                _ => continue,
            }
        }
    }
}
