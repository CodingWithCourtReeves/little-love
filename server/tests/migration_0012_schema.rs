mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_creates_device_push_tokens_table() {
    let store = common::fresh_store().await;
    let cols: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='device_push_tokens'
           AND column_name IN ('account_id','device_id','apns_token','environment','updated_at')",
    )
    .fetch_all(store.pool())
    .await
    .unwrap();
    assert_eq!(cols.len(), 5, "expected all 5 columns, got {cols:?}");
}
