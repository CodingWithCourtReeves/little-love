//! Smoke test: migration 0010 adds the nullable `messages.read_at` column and
//! the partial unread index. Schema-only — no data migration.

mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_adds_read_at_column() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    let col: Option<(String, String, String)> = sqlx::query_as(
        "SELECT column_name, data_type, is_nullable
         FROM information_schema.columns
         WHERE table_name='messages' AND column_name='read_at'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();

    let (name, data_type, is_nullable) = col.expect("messages.read_at should exist");
    assert_eq!(name, "read_at");
    assert_eq!(data_type, "timestamp with time zone");
    assert_eq!(is_nullable, "YES", "read_at must be nullable");

    let idx: Option<(String,)> = sqlx::query_as(
        "SELECT indexname FROM pg_indexes WHERE indexname='messages_recipient_unread_idx'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();
    assert!(idx.is_some(), "messages_recipient_unread_idx should exist");
}
