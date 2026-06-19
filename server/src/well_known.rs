//! Universal-link support served by the API (spec Part B, §B4). iOS fetches
//! the AASA to learn this app claims `littlelove.dev/pair/*`; the landing page
//! is the web fallback when the app isn't installed. Both GETs are inert — a
//! consume requires the app's Ed25519 signature, which a browser GET can't
//! produce.

use axum::extract::Path;
use axum::http::header;
use axum::response::{Html, IntoResponse};

/// `<TeamID>.<bundleID>` for the iOS app.
const APP_ID: &str = "9PVUX2535W.dev.littlelove.littlelove";

/// Serve `.well-known/apple-app-site-association` as `application/json` (no
/// file extension, exact content-type — iOS is strict about both).
pub async fn apple_app_site_association() -> impl IntoResponse {
    let body = serde_json::json!({
        "applinks": {
            "details": [
                {
                    "appIDs": [APP_ID],
                    "components": [
                        { "/": "/pair/*", "comment": "partner pairing links" }
                    ]
                }
            ]
        }
    });
    (
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
}

/// Minimal web fallback for `/pair/:token`. Shown only when the app isn't
/// installed to intercept the universal link. The token is not consumed here.
pub async fn pair_landing(Path(_token): Path<String>) -> impl IntoResponse {
    Html(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<title>Open in LittleLove</title></head>\
<body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:48px\">\
<h1>LittleLove</h1>\
<p>Open this invite in the LittleLove app.</p>\
<p>Don't have it yet? Install LittleLove, then tap the link again.</p>\
</body></html>",
    )
}
