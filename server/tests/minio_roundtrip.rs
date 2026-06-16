//! Live round-trip against a local MinIO, proving the `R2Presigner` output is
//! actually accepted by an S3-compatible store for both PUT and GET. Ignored by
//! default (needs MinIO running); run it explicitly after `./scripts/dev-attachments.sh`:
//!
//!   cargo test -p littlelove-api --test minio_roundtrip -- --ignored --nocapture
//!
//! Env overrides (defaults match docker-compose.minio.yml):
//!   MINIO_ENDPOINT=http://localhost:9000 R2_BUCKET=littlelove-media
//!   R2_ACCESS_KEY_ID=littlelove R2_SECRET_ACCESS_KEY=devsecret123

use std::time::Duration;

use littlelove_api::{config::R2Config, r2::R2Presigner};

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| default.to_string())
}

#[tokio::test]
#[ignore = "requires a local MinIO (./scripts/dev-attachments.sh)"]
async fn presigned_put_then_get_round_trips_against_minio() {
    let presigner = R2Presigner::new(&R2Config {
        account_id: "local".into(),
        bucket: env_or("R2_BUCKET", "littlelove-media"),
        access_key_id: env_or("R2_ACCESS_KEY_ID", "littlelove"),
        secret_access_key: env_or("R2_SECRET_ACCESS_KEY", "devsecret123"),
        endpoint: Some(env_or("MINIO_ENDPOINT", "http://localhost:9000")),
    })
    .unwrap();

    let blob_key = format!("test-{}", uuid::Uuid::new_v4());
    let body = b"the ciphertext bytes that ride to R2".to_vec();
    let client = reqwest::Client::new();

    let put_url = presigner.presign_put(&blob_key, Duration::from_secs(600));
    let put = client
        .put(&put_url)
        .header("content-type", "application/octet-stream")
        .body(body.clone())
        .send()
        .await
        .expect("PUT request");
    assert!(put.status().is_success(), "PUT failed: {} ({put_url})", put.status());

    let get_url = presigner.presign_get(&blob_key, Duration::from_secs(600));
    let got = client.get(&get_url).send().await.expect("GET request");
    assert!(got.status().is_success(), "GET failed: {}", got.status());
    let bytes = got.bytes().await.expect("GET body");
    assert_eq!(bytes.as_ref(), body.as_slice(), "round-tripped bytes differ");
}
