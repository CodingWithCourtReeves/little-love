use std::env;

#[derive(Debug, Clone)]
pub struct R2Config {
    pub account_id: String,
    pub bucket: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    /// Override for the S3 endpoint base URL. Unset in production → the
    /// canonical R2 host is derived from `account_id`. Set to e.g.
    /// `http://localhost:9000` to presign against a local S3-compatible store
    /// (MinIO) for offline end-to-end testing.
    pub endpoint: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ApnsConfig {
    /// Contents of the `.p8` APNs auth key (PEM). Provided directly, not a path,
    /// so it travels as a single deploy secret.
    pub key_p8: String,
    pub key_id: String,
    pub team_id: String,
    /// APNs topic — the app bundle id. Used for alert (message) pushes.
    pub topic: String,
    /// APNs topic for VoIP pushes — the bundle id suffixed with `.voip`. iOS
    /// requires VoIP pushes to use this distinct topic (and a distinct
    /// push-type). Defaults to `{topic}.voip`; override with `APNS_VOIP_TOPIC`.
    pub voip_topic: String,
    /// `sandbox` (dev builds) or `production`.
    pub environment: String,
}

#[derive(Debug, Clone)]
pub struct TurnConfig {
    /// Cloudflare TURN key id; used in the `generate-ice-servers` URL path.
    pub key_id: String,
    /// Bearer token authorizing `generate-ice-servers` for that key.
    pub api_token: String,
    /// Credential TTL in seconds. Set comfortably longer than the longest
    /// expected call; clients can refresh mid-call via `setConfiguration()`.
    pub ttl_secs: u64,
    /// When set, the server returns this JSON `iceServers` blob verbatim instead
    /// of calling Cloudflare — a local coturn / offline stand-in. Mirrors the
    /// `R2_ENDPOINT` → MinIO override pattern.
    pub ice_override: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub database_url: Option<String>,
    pub r2: Option<R2Config>,
    pub apns: Option<ApnsConfig>,
    pub turn: Option<TurnConfig>,
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let port = env::var("PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7707);
        let database_url = env::var("DATABASE_URL").ok().filter(|s| !s.is_empty());
        let r2 = Self::r2_from_env();
        let apns = Self::apns_from_env();
        let turn = Self::turn_from_env();
        Self {
            port,
            database_url,
            r2,
            apns,
            turn,
        }
    }

    pub fn turn_from_env() -> Option<TurnConfig> {
        let get = |k: &str| env::var(k).ok().filter(|s| !s.is_empty());
        Some(TurnConfig {
            key_id: get("TURN_KEY_ID")?,
            api_token: get("TURN_API_TOKEN")?,
            // 2h: a credential is fetched fresh per call, so this bounds the
            // leak/abuse blast radius far better than Cloudflare's 24h example
            // while still exceeding any normal call. Marathon calls refresh
            // mid-session via `setConfiguration()`. Override with TURN_TTL_SECS.
            ttl_secs: get("TURN_TTL_SECS")
                .and_then(|s| s.parse().ok())
                .unwrap_or(7_200),
            ice_override: get("TURN_ICE_OVERRIDE"),
        })
    }

    fn apns_from_env() -> Option<ApnsConfig> {
        let get = |k: &str| env::var(k).ok().filter(|s| !s.is_empty());
        let topic = get("APNS_TOPIC")?;
        let voip_topic = get("APNS_VOIP_TOPIC").unwrap_or_else(|| format!("{topic}.voip"));
        Some(ApnsConfig {
            key_p8: get("APNS_KEY_P8")?,
            key_id: get("APNS_KEY_ID")?,
            team_id: get("APNS_TEAM_ID")?,
            topic,
            voip_topic,
            environment: get("APNS_ENV").unwrap_or_else(|| "sandbox".to_string()),
        })
    }

    fn r2_from_env() -> Option<R2Config> {
        let get = |k: &str| env::var(k).ok().filter(|s| !s.is_empty());
        Some(R2Config {
            account_id: get("R2_ACCOUNT_ID")?,
            bucket: get("R2_BUCKET")?,
            access_key_id: get("R2_ACCESS_KEY_ID")?,
            secret_access_key: get("R2_SECRET_ACCESS_KEY")?,
            endpoint: get("R2_ENDPOINT"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn defaults_to_port_7707_when_env_empty() {
        std::env::remove_var("PORT");
        std::env::remove_var("DATABASE_URL");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 7707);
        assert!(cfg.database_url.is_none());
    }

    #[test]
    #[serial]
    fn reads_port_from_env() {
        std::env::set_var("PORT", "9999");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 9999);
        std::env::remove_var("PORT");
    }

    #[test]
    #[serial]
    fn r2_config_present_when_all_vars_set() {
        for (k, v) in [
            ("R2_ACCOUNT_ID", "acct123"),
            ("R2_BUCKET", "littlelove-media"),
            ("R2_ACCESS_KEY_ID", "akid"),
            ("R2_SECRET_ACCESS_KEY", "secret"),
        ] {
            std::env::set_var(k, v);
        }
        let cfg = ServerConfig::from_env();
        let r2 = cfg.r2.expect("r2 config should be Some when all vars set");
        assert_eq!(r2.account_id, "acct123");
        assert_eq!(r2.bucket, "littlelove-media");
        for k in [
            "R2_ACCOUNT_ID",
            "R2_BUCKET",
            "R2_ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY",
        ] {
            std::env::remove_var(k);
        }
    }

    #[test]
    #[serial]
    fn apns_config_present_when_all_vars_set() {
        for (k, v) in [
            (
                "APNS_KEY_P8",
                "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----",
            ),
            ("APNS_KEY_ID", "KEY123"),
            ("APNS_TEAM_ID", "TEAM456"),
            ("APNS_TOPIC", "dev.littlelove.littlelove"),
            ("APNS_ENV", "sandbox"),
        ] {
            std::env::set_var(k, v);
        }
        // Exercise the derived voip_topic default deterministically.
        std::env::remove_var("APNS_VOIP_TOPIC");
        let cfg = ServerConfig::from_env();
        let apns = cfg.apns.expect("apns config Some when all vars set");
        assert_eq!(apns.key_id, "KEY123");
        assert_eq!(apns.topic, "dev.littlelove.littlelove");
        // voip_topic defaults to the alert topic + ".voip" when unset.
        assert_eq!(apns.voip_topic, "dev.littlelove.littlelove.voip");
        assert_eq!(apns.environment, "sandbox");
        for k in [
            "APNS_KEY_P8",
            "APNS_KEY_ID",
            "APNS_TEAM_ID",
            "APNS_TOPIC",
            "APNS_ENV",
        ] {
            std::env::remove_var(k);
        }
    }

    #[test]
    #[serial]
    fn apns_config_absent_when_vars_missing() {
        for k in [
            "APNS_KEY_P8",
            "APNS_KEY_ID",
            "APNS_TEAM_ID",
            "APNS_TOPIC",
            "APNS_ENV",
        ] {
            std::env::remove_var(k);
        }
        assert!(ServerConfig::from_env().apns.is_none());
    }

    #[test]
    #[serial]
    fn r2_config_absent_when_vars_missing() {
        for k in [
            "R2_ACCOUNT_ID",
            "R2_BUCKET",
            "R2_ACCESS_KEY_ID",
            "R2_SECRET_ACCESS_KEY",
        ] {
            std::env::remove_var(k);
        }
        assert!(ServerConfig::from_env().r2.is_none());
    }

    #[test]
    #[serial]
    fn turn_from_env_reads_key_and_token() {
        std::env::set_var("TURN_KEY_ID", "k123");
        std::env::set_var("TURN_API_TOKEN", "tok");
        std::env::remove_var("TURN_TTL_SECS");
        std::env::remove_var("TURN_ICE_OVERRIDE");
        let cfg = ServerConfig::turn_from_env().expect("turn config Some when key+token set");
        assert_eq!(cfg.key_id, "k123");
        assert_eq!(cfg.api_token, "tok");
        assert_eq!(cfg.ttl_secs, 7_200);
        assert!(cfg.ice_override.is_none());
        std::env::remove_var("TURN_KEY_ID");
        std::env::remove_var("TURN_API_TOKEN");
    }

    #[test]
    #[serial]
    fn turn_ttl_and_override_are_read() {
        std::env::set_var("TURN_KEY_ID", "k123");
        std::env::set_var("TURN_API_TOKEN", "tok");
        std::env::set_var("TURN_TTL_SECS", "120");
        std::env::set_var("TURN_ICE_OVERRIDE", r#"{"iceServers":[]}"#);
        let cfg = ServerConfig::turn_from_env().expect("turn config Some");
        assert_eq!(cfg.ttl_secs, 120);
        assert_eq!(cfg.ice_override.as_deref(), Some(r#"{"iceServers":[]}"#));
        for k in [
            "TURN_KEY_ID",
            "TURN_API_TOKEN",
            "TURN_TTL_SECS",
            "TURN_ICE_OVERRIDE",
        ] {
            std::env::remove_var(k);
        }
    }

    #[test]
    #[serial]
    fn turn_config_absent_when_vars_missing() {
        for k in ["TURN_KEY_ID", "TURN_API_TOKEN"] {
            std::env::remove_var(k);
        }
        assert!(ServerConfig::turn_from_env().is_none());
    }
}
