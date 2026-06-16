mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_creates_attachments_table() {
    let store = common::fresh_store().await;
    let cols: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='attachments'
           AND column_name IN ('blob_key','room_id','uploader_account_id','byte_size','committed','created_at')",
    )
    .fetch_all(store.pool())
    .await
    .unwrap();
    assert_eq!(cols.len(), 6, "expected all 6 attachments columns, got {cols:?}");
}
