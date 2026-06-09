use std::env;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub database_url: Option<String>,
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let port = env::var("PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7707);
        let database_url = env::var("DATABASE_URL").ok().filter(|s| !s.is_empty());
        Self { port, database_url }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_port_7707_when_env_empty() {
        std::env::remove_var("PORT");
        std::env::remove_var("DATABASE_URL");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 7707);
        assert!(cfg.database_url.is_none());
    }

    #[test]
    fn reads_port_from_env() {
        std::env::set_var("PORT", "9999");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 9999);
        std::env::remove_var("PORT");
    }
}
