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
    let state = AppState { routing: Routing::new(), store };
    let app = Router::new()
        .route("/health", get(health))
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
