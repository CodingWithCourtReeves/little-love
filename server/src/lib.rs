pub mod accounts;
pub mod attachments;
pub mod calls;
pub mod config;
pub mod diag;
pub mod invites;
pub mod profiles;
pub mod push;
pub mod push_tokens;
pub mod r2;
pub mod rooms;
pub mod routing;
pub mod store;
pub mod turn;
pub mod well_known;
pub mod wire;
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
