use std::net::SocketAddr;
use std::time::Duration;

use axum::{routing::get, Router};
use chrono::Utc;
use futures::{SinkExt, StreamExt};
use littlelove_api::{
    routing::Routing,
    store::{MessageRow, Store},
    ws::{ws_handler, AppState, USER_HEADER},
};
use tokio::net::TcpListener;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message,
};
use uuid::Uuid;

async fn spawn_server(store: Store) -> SocketAddr {
    let state = AppState {
        routing: Routing::new(),
        store: Some(store),
    };
    let app = Router::new().route("/ws", get(ws_handler)).with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    addr
}

fn db_url() -> String {
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

#[tokio::test]
async fn stores_and_replays_history_for_disconnected_recipient() {
    let store = Store::connect(&db_url()).await.unwrap();
    sqlx::query("TRUNCATE TABLE messages")
        .execute(store.pool())
        .await
        .unwrap();

    // Seed one stored message addressed to kaitlyn.
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "hey love".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();

    let addr = spawn_server(store).await;

    let url = format!("ws://{addr}/ws");
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(USER_HEADER, "kaitlyn".parse().unwrap());
    let (mut sock, _) = connect_async(req).await.unwrap();

    sock.send(Message::Text(
        serde_json::json!({
            "type": "hello",
            "since": (Utc::now() - chrono::Duration::days(1)).to_rfc3339()
        })
        .to_string(),
    ))
    .await
    .unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), sock.next())
        .await
        .expect("kaitlyn should receive a replay within 2s")
        .expect("stream closed")
        .expect("recv error");
    let text = match received {
        Message::Text(t) => t,
        other => panic!("expected text, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["body"], "hey love");
    assert_eq!(value["replayed"], true);
}
