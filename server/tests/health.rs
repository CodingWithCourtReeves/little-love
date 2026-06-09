use std::time::Duration;

#[tokio::test]
async fn health_returns_ok() {
    // Spawn the binary on a known free port.
    let port: u16 = portpicker::pick_unused_port().expect("a free port");
    let mut cmd = tokio::process::Command::new(env!("CARGO_BIN_EXE_littlelove-api"))
        .env("PORT", port.to_string())
        .spawn()
        .expect("server starts");

    // Poll /health up to 5s for readiness.
    let url = format!("http://127.0.0.1:{port}/health");
    let mut last_err = None;
    for _ in 0..50 {
        match reqwest::get(&url).await {
            Ok(r) if r.status().is_success() => {
                cmd.kill().await.ok();
                return;
            }
            Ok(r) => last_err = Some(format!("status {}", r.status())),
            Err(e) => last_err = Some(e.to_string()),
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    cmd.kill().await.ok();
    panic!("server never became healthy: {last_err:?}");
}
