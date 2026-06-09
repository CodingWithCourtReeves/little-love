pub mod config;
pub mod routing;
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
