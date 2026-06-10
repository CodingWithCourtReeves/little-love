//! End-to-end smoke for the memory + summary refresh loop with a mocked LLM.

use std::sync::Arc;
use std::time::Duration;

use axum::{routing::post, Json, Router};
use serde_json::json;
use tempfile::tempdir;
use tokio::sync::Mutex;

use littlelove_bot::llm::LlmClient;
use littlelove_bot::memory::{Memory, Role};
use littlelove_bot::summary_task::run_summary_refresh;

#[tokio::test]
async fn summary_refresh_writes_row_against_mock_llm() {
    let canned = "EVENTS:\nThey said hi several times.\nCHARACTER:\nI feel curious.";
    let app = Router::new().route(
        "/v1/chat/completions",
        post(move |Json(_): Json<serde_json::Value>| async move {
            Json(json!({"choices":[{"message":{"content": canned}}]}))
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let dir = tempdir().unwrap();
    let mut m = Memory::open(dir.path(), "01TESTROOM").unwrap();
    for i in 0..5 {
        m.record_turn(Role::User, &format!("u{i}")).unwrap();
        m.record_turn(Role::Assistant, &format!("a{i}")).unwrap();
    }
    let mem = Arc::new(Mutex::new(m));

    let llm = Arc::new(
        LlmClient::new(
            &format!("http://{addr}/v1"),
            "test",
            0.8,
            512,
            Duration::from_secs(5),
        )
        .unwrap(),
    );
    run_summary_refresh(mem.clone(), llm, "Nova".into(), "alice".into())
        .await
        .unwrap();

    let m = mem.lock().await;
    let s = m.summary().expect("summary populated");
    assert_eq!(s.events.trim(), "They said hi several times.");
    assert_eq!(s.character.trim(), "I feel curious.");
}
