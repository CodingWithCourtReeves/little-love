pub mod accounts;
pub mod auth;
pub mod config;
pub mod invites;
pub mod rooms;
pub mod routing;
pub mod store;
pub mod wire;
pub mod wordlist_bip39_en;
pub mod ws;

pub fn placeholder() -> &'static str {
    "littlelove-api"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_returns_service_name() {
        assert_eq!(placeholder(), "littlelove-api");
    }
}
