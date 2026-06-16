//! Smoke test: migration 0006 applies cleanly on top of 0001–0005 and
//! exposes the v0.3 schema deltas (is_bot/owner/partner on accounts,
//! rooms.name, invites.room_id, dropped monogamy index).

mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_0006_creates_new_columns() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    let cols: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='accounts'
           AND column_name IN ('is_bot','owner_account_id','partner_account_id')",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    assert_eq!(
        cols.len(),
        3,
        "expected is_bot/owner_account_id/partner_account_id, got {cols:?}"
    );

    let name_col: Option<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='rooms' AND column_name='name'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();
    assert!(name_col.is_some(), "rooms.name missing");

    let inv_room: Option<(String,)> = sqlx::query_as(
        "SELECT column_name FROM information_schema.columns
         WHERE table_name='invites' AND column_name='room_id'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();
    assert!(inv_room.is_some(), "invites.room_id missing");

    let idx: Option<(String,)> = sqlx::query_as(
        "SELECT indexname FROM pg_indexes
         WHERE indexname='room_members_one_per_account'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();
    assert!(idx.is_none(), "v0.2 monogamy index should be dropped");
}
