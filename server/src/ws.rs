use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::IntoResponse,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::routing::Routing;
use crate::store::{MessageRow, Store};
use crate::wire::{ClientFrame, ServerFrame};

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
}

/// Header used as Day-1 "auth": the connecting username.
pub const USER_HEADER: &str = "x-llove-user";

pub async fn ws_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let username = headers
        .get(USER_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    ws.on_upgrade(move |socket| async move {
        match username {
            Some(name) => handle_socket(socket, name, state).await,
            None => warn!("WS upgrade rejected: missing {USER_HEADER}"),
        }
    })
}

async fn handle_socket(socket: WebSocket, username: String, state: AppState) {
    info!(%username, "client connected");
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
                    // x-llove-user header is Day-1 auth; trust it, not the client-supplied `from`.
                    payload.from = username.clone();
                    if let Some(store) = &state.store {
                        if let Err(e) =
                            store.insert(MessageRow::from(payload.clone())).await
                        {
                            warn!("store insert failed: {e}");
                        }
                    }
                    let to = payload.to.clone();
                    let delivered =
                        state.routing.deliver(&to, ServerFrame::Msg(payload)).await;
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
                        info!("hello received but store disabled (Day-1a mode)");
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
