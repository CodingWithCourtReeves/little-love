//! REST client. Only `POST /accounts` is needed; everything else moves
//! through the WSS frame stream.

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
pub struct SignupRequest {
    pub username: String,
    pub ed25519_pub_b64: String,
    pub x25519_pub_b64: String,
}

#[derive(Debug, Deserialize)]
pub struct SignupResponse {
    pub username: String,
    pub created_at: DateTime<Utc>,
}

pub async fn signup(base_url: &str, req: &SignupRequest) -> Result<SignupResponse> {
    let url = format!("{}/accounts", base_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "username": req.username,
        "ed25519_pub": req.ed25519_pub_b64,
        "x25519_pub": req.x25519_pub_b64,
    });
    let resp = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .with_context(|| format!("POST {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("signup failed {status}: {text}"));
    }
    Ok(resp.json::<SignupResponse>().await?)
}
