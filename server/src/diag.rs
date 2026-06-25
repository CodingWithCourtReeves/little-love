//! Diagnostic endpoints. Inert unless explicitly enabled via env.

use axum::http::{HeaderMap, StatusCode};

/// `GET /__diag/error-test` forces a synthetic error event so we can verify the
/// error-monitoring pipeline end to end (event reaches Bugsink, alert email
/// fires). Gated behind `DIAG_TOKEN`:
///
/// - `DIAG_TOKEN` unset/empty  -> 404 (route is inert).
/// - set, caller's `X-Diag-Token` header missing or wrong -> 404 (don't reveal
///   the route exists).
/// - set + correct header -> capture a content-free message, return 200.
///
/// MUST NOT emit user data.
pub async fn error_test(headers: HeaderMap) -> StatusCode {
    let Some(expected) = std::env::var("DIAG_TOKEN").ok().filter(|s| !s.is_empty()) else {
        return StatusCode::NOT_FOUND;
    };
    let provided = headers
        .get("x-diag-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    if !ct_eq(provided.as_bytes(), expected.as_bytes()) {
        return StatusCode::NOT_FOUND;
    }
    sentry::capture_message(
        "diag: synthetic test event from /__diag/error-test",
        sentry::Level::Error,
    );
    StatusCode::OK
}

/// Constant-time byte comparison so the token check doesn't leak how many
/// leading bytes matched via response timing. (The length short-circuit leaks
/// only the length, which is not secret.)
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn headers_with(token: Option<&str>) -> HeaderMap {
        let mut h = HeaderMap::new();
        if let Some(t) = token {
            h.insert("x-diag-token", t.parse().unwrap());
        }
        h
    }

    #[tokio::test]
    #[serial]
    async fn returns_404_when_diag_token_unset() {
        std::env::remove_var("DIAG_TOKEN");
        assert_eq!(
            error_test(headers_with(Some("anything"))).await,
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    #[serial]
    async fn returns_404_when_header_missing_or_wrong() {
        std::env::set_var("DIAG_TOKEN", "s3cret");
        assert_eq!(error_test(headers_with(None)).await, StatusCode::NOT_FOUND);
        assert_eq!(
            error_test(headers_with(Some("nope"))).await,
            StatusCode::NOT_FOUND
        );
        std::env::remove_var("DIAG_TOKEN");
    }

    #[tokio::test]
    #[serial]
    async fn returns_200_when_token_matches() {
        std::env::set_var("DIAG_TOKEN", "s3cret");
        assert_eq!(
            error_test(headers_with(Some("s3cret"))).await,
            StatusCode::OK
        );
        std::env::remove_var("DIAG_TOKEN");
    }
}
