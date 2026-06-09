use chrono::Utc;
use littlelove_api::store::{MessageRow, Store};
use uuid::Uuid;

fn database_url() -> String {
    std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set; run via dev-up or set it manually")
}

async fn fresh_store() -> Store {
    let store = Store::connect(&database_url()).await.expect("connect");
    sqlx::query("TRUNCATE TABLE messages")
        .execute(store.pool())
        .await
        .expect("truncate");
    store
}

#[tokio::test]
async fn store_and_replay_round_trip() {
    let store = fresh_store().await;
    let id = Uuid::new_v4();
    let now = Utc::now();
    store
        .insert(MessageRow {
            id,
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "hi".into(),
            ts: now,
        })
        .await
        .expect("insert");

    let history = store
        .messages_for("kaitlyn", now - chrono::Duration::seconds(1))
        .await
        .expect("query");
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].body, "hi");
}

#[tokio::test]
async fn store_only_returns_messages_addressed_to_user() {
    let store = fresh_store().await;
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "for k".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "kaitlyn".into(),
            to_user: "court".into(),
            body: "for c".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();

    let for_kaitlyn = store
        .messages_for("kaitlyn", Utc::now() - chrono::Duration::days(1))
        .await
        .unwrap();
    assert_eq!(for_kaitlyn.len(), 1);
    assert_eq!(for_kaitlyn[0].body, "for k");
}
