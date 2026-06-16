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
pub struct ServerConfig {
    pub port: u16,
    pub database_url: Option<String>,
    pub r2: Option<R2Config>,
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let port = env::var("PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7707);
        let database_url = env::var("DATABASE_URL").ok().filter(|s| !s.is_empty());
        let r2 = Self::r2_from_env();
        Self {
            port,
            database_url,
            r2,
        }
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
}
