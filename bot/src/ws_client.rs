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
use uuid::Uuid;

pub struct ClientIdentity {
    pub username: String,
    pub ed25519_signing: SigningKey,
}

pub struct Session {
    pub socket: WsStream,
    pub initial_rooms: Vec<RoomDescriptor>,
    pub self_username: String,
}

pub type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// v0.3 wire-level member (spec §7.1).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Member {
    pub username: String,
    pub ed25519_pub: String,
    pub x25519_pub: String,
    #[serde(default)]
    pub is_bot: bool,
    #[serde(default)]
    pub owner_username: Option<String>,
}

/// v0.3 `RoomDetail` (spec §7.1) — carried inside `Rooms`, `RoomCreated`,
/// `InviteConsumed`.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct RoomDetail {
    pub room_id: String,
    #[serde(default)]
    pub name: String,
    pub members: Vec<Member>,
    /// `Rooms` carries this; the struct variants `InviteConsumed` /
    /// `RoomCreated` don't (spec §8.2). Default to `None` so the same type
    /// works for both shapes.
    #[serde(default)]
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// Flat "the other side" view the bot has used since v0.2. In v0.3 the
/// wire carries the full roster; this struct is derived from it so the run
/// loop continues to read `peer_*` fields without per-call lookup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomDescriptor {
    pub room_id: String,
    pub peer_username: String,
    pub peer_ed25519_pub: String,
    pub peer_x25519_pub: String,
}

impl RoomDescriptor {
    /// Build the v0.2-shaped descriptor from a v0.3 `RoomDetail`. Picks the
    /// first non-self member as "the peer" — the bot only joins couple-shape
    /// rooms (one human + one bot), so the choice is unambiguous.
    pub fn from_detail(detail: &RoomDetail, self_username: &str) -> Result<Self> {
        let peer = detail
            .members
            .iter()
            .find(|m| m.username != self_username)
            .ok_or_else(|| {
                anyhow!(
                    "room {} has no member other than self ({self_username})",
                    detail.room_id
                )
            })?;
        Ok(Self {
            room_id: detail.room_id.clone(),
            peer_username: peer.username.clone(),
            peer_ed25519_pub: peer.ed25519_pub.clone(),
            peer_x25519_pub: peer.x25519_pub.clone(),
        })
    }
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum ServerFrame {
    Challenge {
        nonce: String,
    },
    Authenticated,
    Rooms {
        rooms: Vec<RoomDetail>,
        // owned_bots is sent by v0.3 servers; the bot has no use for it and
        // shouldn't fail to decode if older / different servers omit it.
        #[serde(default)]
        #[allow(dead_code)]
        owned_bots: Vec<Member>,
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
            ServerFrame::Rooms {
                rooms,
                owned_bots: _,
            } => break rooms,
            ServerFrame::Error { code, message } => {
                return Err(anyhow!("auth error: {code} {message}"));
            }
            ServerFrame::Challenge { .. } => {
                return Err(anyhow!("unexpected second Challenge"));
            }
        }
    };
    let initial_rooms = initial_rooms
        .iter()
        .map(|d| RoomDescriptor::from_detail(d, &identity.username))
        .collect::<Result<Vec<_>>>()?;
    Ok(Session {
        socket: sock,
        initial_rooms,
        self_username: identity.username.clone(),
    })
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
#[allow(dead_code)]
enum RoomServerFrame {
    InviteConsumed(RoomDetail),
    RoomCreated(RoomDetail),
    Rooms {
        rooms: Vec<RoomDetail>,
        #[serde(default)]
        #[allow(dead_code)]
        owned_bots: Vec<Member>,
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
                RoomServerFrame::InviteConsumed(detail) => {
                    return RoomDescriptor::from_detail(&detail, &identity.username);
                }
                RoomServerFrame::Error { code, message } => {
                    return Err(anyhow!("consume invite error: {code} {message}"));
                }
                _ => continue,
            }
        }
    }
}

/// Inbound frame variants the run loop cares about. Variants the bot
/// never expects to receive (e.g. RoomCreated for a paired bot) are
/// deserialized into `Other` and silently dropped.
#[derive(Debug, Clone)]
pub enum Inbound {
    Message {
        id: String,
        room_id: String,
        from: String,
        ts: chrono::DateTime<chrono::Utc>,
        body: String,
        replayed: bool,
    },
    Other,
}

#[derive(Deserialize)]
#[serde(tag = "kind")]
enum InboundRaw {
    Message {
        id: String,
        room_id: String,
        from: String,
        ts: chrono::DateTime<chrono::Utc>,
        body: String,
        #[serde(default)]
        replayed: bool,
    },
    #[serde(other)]
    Other,
}

pub async fn next_inbound(session: &mut Session) -> Result<Option<Inbound>> {
    while let Some(msg) = session.socket.next().await {
        let m = msg?;
        if let Message::Text(t) = m {
            let parsed: InboundRaw = match serde_json::from_str(&t) {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!("skip un-parseable frame: {e}");
                    continue;
                }
            };
            return Ok(Some(match parsed {
                InboundRaw::Message {
                    id,
                    room_id,
                    from,
                    ts,
                    body,
                    replayed,
                } => Inbound::Message {
                    id,
                    room_id,
                    from,
                    ts,
                    body,
                    replayed,
                },
                InboundRaw::Other => Inbound::Other,
            }));
        }
    }
    Ok(None)
}

pub async fn subscribe(session: &mut Session, room_id: &str) -> Result<()> {
    let frame = serde_json::json!({
        "kind": "Subscribe",
        "room_id": room_id,
        "since_message_id": serde_json::Value::Null,
    });
    session
        .socket
        .send(Message::Text(frame.to_string()))
        .await?;
    Ok(())
}

/// v0.3 `Send` (spec §6.2 / §8.2). The bot only ever sits in couple-shape
/// rooms — one peer — so `bodies` always has exactly one entry, keyed by
/// the peer's x25519 pubkey (base64).
pub async fn send_message(
    session: &mut Session,
    room_id: &str,
    peer_x25519_pub_b64: &str,
    wire_body: &str,
) -> Result<()> {
    let mut bodies = std::collections::HashMap::new();
    bodies.insert(peer_x25519_pub_b64.to_string(), wire_body.to_string());
    let frame = serde_json::json!({
        "kind": "Send",
        "room_id": room_id,
        "bodies": bodies,
        "client_msg_id": Uuid::new_v4(),
    });
    session
        .socket
        .send(Message::Text(frame.to_string()))
        .await?;
    Ok(())
}
