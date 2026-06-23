//! TURN ICE-server provider.
//!
//! Default path: ask Cloudflare to mint short-lived ICE credentials via
//! `generate-ice-servers`. The relay only forwards already-encrypted SRTP, so
//! E2EE is preserved (the server never touches media keys).
//!
//! Override path (`TURN_ICE_OVERRIDE`): return a static `iceServers` JSON blob
//! verbatim — a local coturn / offline stand-in, mirroring the `R2_ENDPOINT` →
//! MinIO override used elsewhere.

use crate::config::TurnConfig;
use serde_json::Value;

/// Parse a caller-supplied `iceServers` JSON blob (the offline/coturn override).
pub fn ice_servers_from_override(raw: &str) -> anyhow::Result<Value> {
    Ok(serde_json::from_str(raw)?)
}

/// Resolve the ICE servers to hand a client for a call.
///
/// Returns the parsed JSON object Cloudflare produces (an `{ "iceServers": [..] }`
/// shape), or the static override when configured.
pub async fn ice_servers(cfg: &TurnConfig, http: &reqwest::Client) -> anyhow::Result<Value> {
    if let Some(raw) = &cfg.ice_override {
        return ice_servers_from_override(raw);
    }
    let url = format!(
        "https://rtc.live.cloudflare.com/v1/turn/keys/{}/credentials/generate-ice-servers",
        cfg.key_id
    );
    let body = serde_json::json!({ "ttl": cfg.ttl_secs });
    let resp = http
        .post(url)
        .bearer_auth(&cfg.api_token)
        .json(&body)
        .send()
        .await?
        .error_for_status()?;
    Ok(resp.json::<Value>().await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn override_path_parses_ice_servers() {
        let raw = r#"{"iceServers":[{"urls":"stun:stun.example:3478"}]}"#;
        let v = ice_servers_from_override(raw).unwrap();
        assert!(v.get("iceServers").unwrap().is_array());
    }

    #[test]
    fn override_rejects_garbage() {
        assert!(ice_servers_from_override("not json").is_err());
    }
}
