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
use crate::store::{MessageRow, Store};
use crate::wire::{AuthClientFrame, AuthServerFrame, ClientFrame, IdentifyPayload, ServerFrame};

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
}

/// WSS close code for auth failures (spec §3.3 step 6).
const CLOSE_AUTH_FAILED: u16 = 4001;

pub async fn ws_handler(
    State(state): State<AppState>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
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
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerFrame>();
    state.routing.register(username.clone(), tx.clone()).await;

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
            match serde_json::from_str::<ClientFrame>(&text) {
                Ok(ClientFrame::Msg(mut payload)) => {
                    // Authenticated identity overrides any client-supplied `from`.
                    payload.from = username.clone();
                    if let Some(store) = &state.store {
                        if let Err(e) = store.insert(MessageRow::from(payload.clone())).await {
                            warn!("store insert failed: {e}");
                        }
                    }
                    let to = payload.to.clone();
                    let delivered = state.routing.deliver(&to, ServerFrame::Msg(payload)).await;
                    if !delivered {
                        info!(%to, "recipient offline; stored only");
                    }
                }
                Ok(ClientFrame::Hello(h)) => {
                    if let Some(store) = &state.store {
                        match store.messages_for(&username, h.since).await {
                            Ok(rows) => {
                                for row in rows {
                                    let frame = ServerFrame::Msg(row.into_payload(true));
                                    let _ = tx.send(frame);
                                }
                            }
                            Err(e) => warn!("replay query failed: {e}"),
                        }
                    } else {
                        info!("hello received but store disabled");
                    }
                }
                Err(e) => warn!("invalid frame from {username}: {e}"),
            }
        }
    }

    state.routing.unregister(&username).await;
    outbound.abort();
    info!(%username, "client disconnected");
}
