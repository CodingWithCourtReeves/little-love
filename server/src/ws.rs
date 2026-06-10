use axum::{
    extract::{
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::accounts::lookup_ed25519_pub;
use crate::auth::{decode_b64, encode_b64, random_nonce, verify_signature};
use crate::routing::Routing;
use crate::store::Store;
use crate::wire::{
    error_codes, AuthClientFrame, AuthServerFrame, IdentifyPayload, RoomClientFrame,
    RoomServerFrame,
};

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
}

/// WSS close code for auth failures (spec §3.3 step 6).
const CLOSE_AUTH_FAILED: u16 = 4001;

pub async fn ws_handler(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Run the Challenge → Identify → Authenticated handshake.
/// Returns the authenticated username on success.
async fn handshake(socket: &mut WebSocket, state: &AppState) -> Option<String> {
    let nonce = random_nonce();
    let challenge = AuthServerFrame::Challenge {
        nonce: encode_b64(&nonce),
    };
    if socket
        .send(Message::Text(serde_json::to_string(&challenge).ok()?))
        .await
        .is_err()
    {
        return None;
    }

    let raw = match socket.next().await {
        Some(Ok(Message::Text(t))) => t,
        _ => {
            close_auth_failed(socket).await;
            return None;
        }
    };

    let frame: AuthClientFrame = match serde_json::from_str(&raw) {
        Ok(f) => f,
        Err(_) => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let AuthClientFrame::Identify(IdentifyPayload {
        username,
        signature,
    }) = frame;

    let store = match state.store.as_ref() {
        Some(s) => s,
        None => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let pub_key = match lookup_ed25519_pub(store, &username).await {
        Ok(Some(b)) => b,
        _ => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    let sig_bytes = match decode_b64(&signature) {
        Ok(b) => b,
        Err(_) => {
            close_auth_failed(socket).await;
            return None;
        }
    };
    if verify_signature(&pub_key, &nonce, &sig_bytes).is_err() {
        close_auth_failed(socket).await;
        return None;
    }

    let ok = serde_json::to_string(&AuthServerFrame::Authenticated).ok()?;
    if socket.send(Message::Text(ok)).await.is_err() {
        return None;
    }
    Some(username)
}

async fn close_auth_failed(socket: &mut WebSocket) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code: CLOSE_AUTH_FAILED,
            reason: "auth failed".into(),
        })))
        .await;
}

async fn handle_socket(mut socket: WebSocket, state: AppState) {
    let username = match handshake(&mut socket, &state).await {
        Some(u) => u,
        None => return,
    };
    info!(%username, "client authenticated");

    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<RoomServerFrame>();
    state.routing.register(username.clone(), tx.clone()).await;

    // Spec §8.2: server pushes the user's room list immediately after
    // Authenticated. Until the rooms DB ops land, this is an empty list
    // — sending the frame still confirms the post-auth contract is wired.
    let _ = tx.send(RoomServerFrame::Rooms { rooms: Vec::new() });

    let outbound = tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            let text = match serde_json::to_string(&frame) {
                Ok(s) => s,
                Err(e) => {
                    warn!("failed to serialize outbound frame: {e}");
                    continue;
                }
            };
            if sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(msg)) = stream.next().await {
        if let Message::Text(text) = msg {
            match serde_json::from_str::<RoomClientFrame>(&text) {
                Ok(RoomClientFrame::CreateInvite) => {
                    // TODO(WT-B T5): generate_invite, persist, encode QR,
                    // reply InviteCreated. For now, return a not-implemented
                    // error so callers see a coherent frame.
                    let _ = tx.send(RoomServerFrame::Error {
                        code: "NotImplemented".into(),
                        message: "CreateInvite handler pending".into(),
                    });
                }
                Ok(RoomClientFrame::ConsumeInvite { .. }) => {
                    let _ = tx.send(RoomServerFrame::Error {
                        code: "NotImplemented".into(),
                        message: "ConsumeInvite handler pending".into(),
                    });
                }
                Ok(RoomClientFrame::Subscribe { .. }) => {
                    let _ = tx.send(RoomServerFrame::Error {
                        code: error_codes::UNKNOWN_ROOM.into(),
                        message: "Subscribe handler pending".into(),
                    });
                }
                Ok(RoomClientFrame::Send { .. }) => {
                    let _ = tx.send(RoomServerFrame::Error {
                        code: error_codes::UNKNOWN_ROOM.into(),
                        message: "Send handler pending".into(),
                    });
                }
                Err(e) => warn!("invalid frame from {username}: {e}"),
            }
        }
    }

    state.routing.unregister(&username, &tx).await;
    outbound.abort();
    info!(%username, "client disconnected");
}
