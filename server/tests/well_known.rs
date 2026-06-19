mod common;
use common::spawn_server;

#[tokio::test]
async fn aasa_advertises_the_app_id_and_pair_path() {
    let addr = spawn_server(None).await;
    let resp = reqwest::Client::new()
        .get(format!(
            "http://{addr}/.well-known/apple-app-site-association"
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        resp.headers()["content-type"],
        "application/json",
        "AASA must be served as application/json"
    );
    let body: serde_json::Value = resp.json().await.unwrap();
    let details = &body["applinks"]["details"][0];
    assert_eq!(details["appIDs"][0], "9PVUX2535W.dev.littlelove.littlelove");
    assert_eq!(details["components"][0]["/"], "/pair/*");
}

#[tokio::test]
async fn pair_landing_serves_html() {
    let addr = spawn_server(None).await;
    let resp = reqwest::Client::new()
        .get(format!("http://{addr}/pair/abandon-pilot-react-zoo"))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert!(resp.headers()["content-type"]
        .to_str()
        .unwrap()
        .starts_with("text/html"));
    let body = resp.text().await.unwrap();
    assert!(body.contains("LittleLove"));
}
