use std::net::SocketAddr;
use std::time::Duration;

use axum::{routing::get, Router};
use futures::{SinkExt, StreamExt};
use littlelove_api::{
    routing::Routing,
    ws::{ws_handler, AppState, USER_HEADER},
};
use tokio::net::TcpListener;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message,
};

async fn spawn_server() -> SocketAddr {
    let state = AppState { routing: Routing::new(), store: None };
    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    addr
}

async fn connect(
    addr: SocketAddr,
    user: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let url = format!("ws://{}/ws", addr);
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(USER_HEADER, user.parse().unwrap());
    let (sock, _resp) = connect_async(req).await.unwrap();
    sock
}

#[tokio::test]
async fn server_overrides_from_with_authenticated_username() {
    let addr = spawn_server().await;
    let mut court = connect(addr, "court").await;
    let mut kaitlyn = connect(addr, "kaitlyn").await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Court is connected as "court" but spoofs from=eve in the payload.
    let frame = serde_json::json!({
        "type": "msg",
        "id": "8c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "from": "eve",
        "to": "kaitlyn",
        "body": "fake",
        "ts": "2026-06-09T17:00:00Z"
    });
    court.send(Message::Text(frame.to_string())).await.unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), kaitlyn.next())
        .await
        .expect("kaitlyn should receive a frame within 2s")
        .expect("stream closed")
        .expect("recv error");
    let text = match received {
        Message::Text(t) => t,
        other => panic!("expected text frame, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    // Server must have overridden `from` to the header value.
    assert_eq!(value["from"], "court");
}

#[tokio::test]
async fn forwards_message_to_recipient_when_both_connected() {
    let addr = spawn_server().await;
    let mut court = connect(addr, "court").await;
    let mut kaitlyn = connect(addr, "kaitlyn").await;

    // Give both connections a moment to register in the routing table.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let frame = serde_json::json!({
        "type": "msg",
        "id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "from": "court",
        "to": "kaitlyn",
        "body": "hey love",
        "ts": "2026-06-09T17:00:00Z"
    });
    court.send(Message::Text(frame.to_string())).await.unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), kaitlyn.next())
        .await
        .expect("kaitlyn should receive a frame within 2s")
        .expect("stream closed")
        .expect("recv error");

    let text = match received {
        Message::Text(t) => t,
        other => panic!("expected text frame, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["from"], "court");
    assert_eq!(value["to"], "kaitlyn");
    assert_eq!(value["body"], "hey love");
}
