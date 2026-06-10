use std::net::SocketAddr;

use axum::{routing::post, Json, Router};
use tokio::net::TcpListener;

use littlelove_bot::history::{History, Role};
use littlelove_bot::llm::{LlmClient, LlmRequest};

#[tokio::test]
async fn mock_chat_returns_reply() {
    let app = Router::new().route(
        "/chat/completions",
        post(|Json(_): Json<serde_json::Value>| async {
            Json(serde_json::json!({
                "choices": [{ "message": { "role": "assistant", "content": "ok" } }]
            }))
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let base = format!("http://{addr}");
    let client = LlmClient::new(
        &base,
        "test-model",
        0.5,
        64,
        std::time::Duration::from_secs(5),
    )
    .expect("client");
    let mut history = History::new(5);
    history.push(Role::User, "hello".into());
    let reply = client
        .chat(&LlmRequest {
            system_prompt: "be brief".into(),
            history: &history,
            latest_user: "hello",
        })
        .await
        .expect("chat");
    assert_eq!(reply.trim(), "ok");
}
