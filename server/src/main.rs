use anyhow::Result;
use axum::{routing::get, Router};
use littlelove_api::{
    config::ServerConfig,
    routing::Routing,
    store::Store,
    ws::{ws_handler, AppState},
};
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,littlelove_api=info")),
        )
        .init();

    let cfg = ServerConfig::from_env();
    let store = match cfg.database_url.as_deref() {
        Some(url) => Some(Store::connect(url).await?),
        None => {
            tracing::warn!("DATABASE_URL unset; running without persistence (Day-1a mode)");
            None
        }
    };
    let r2 = match cfg.r2.as_ref() {
        Some(r2cfg) => match littlelove_api::r2::R2Presigner::new(r2cfg) {
            Ok(p) => Some(p),
            Err(e) => {
                tracing::warn!("R2 presigner init failed; attachments disabled: {e}");
                None
            }
        },
        None => {
            tracing::warn!("R2_* env unset; attachments disabled");
            None
        }
    };
    let push: Option<std::sync::Arc<dyn littlelove_api::push::PushSender>> = match cfg.apns.as_ref()
    {
        Some(apnscfg) => match littlelove_api::push::ApnsSender::new(apnscfg) {
            Ok(s) => Some(std::sync::Arc::new(s)),
            Err(e) => {
                tracing::warn!("APNs sender init failed; push disabled: {e}");
                None
            }
        },
        None => {
            tracing::warn!("APNS_* env unset; push notifications disabled");
            None
        }
    };
    let state = AppState {
        routing: Routing::new(),
        store,
        r2,
        push,
    };
    let app = Router::new()
        .route("/health", get(health))
        .route(
            "/accounts",
            axum::routing::post(littlelove_api::accounts::create_account),
        )
        .route(
            "/accounts/by-username/:username",
            get(littlelove_api::accounts::get_account_by_username),
        )
        .route(
            "/invites/:code/preview",
            axum::routing::post(littlelove_api::invites::preview_invite),
        )
        .route(
            "/.well-known/apple-app-site-association",
            get(littlelove_api::well_known::apple_app_site_association),
        )
        .route(
            "/pair/:token",
            get(littlelove_api::well_known::pair_landing),
        )
        .route("/ws", get(ws_handler))
        .with_state(state);

    let addr: SocketAddr = format!("0.0.0.0:{}", cfg.port).parse()?;
    tracing::info!("listening on {addr}");
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> &'static str {
    "ok"
}
