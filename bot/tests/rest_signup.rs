use std::net::SocketAddr;

use axum::{routing::post, Json, Router};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;

use littlelove_bot::rest::{signup, SignupRequest};

#[tokio::test]
async fn signup_round_trips() {
    #[derive(Deserialize)]
    struct In {
        username: String,
        ed25519_pub: String,
        x25519_pub: String,
    }
    #[derive(Serialize)]
    struct Out {
        username: String,
        created_at: chrono::DateTime<chrono::Utc>,
    }

    let app = Router::new().route(
        "/accounts",
        post(|Json(req): Json<In>| async move {
            let _ = (&req.ed25519_pub, &req.x25519_pub);
            Json(Out {
                username: req.username,
                created_at: chrono::Utc::now(),
            })
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

    let base = format!("http://{addr}");
    let resp = signup(
        &base,
        &SignupRequest {
            username: "court_familiar".into(),
            ed25519_pub_b64: "AAAA".into(),
            x25519_pub_b64: "BBBB".into(),
        },
    )
    .await
    .expect("signup");
    assert_eq!(resp.username, "court_familiar");
}
