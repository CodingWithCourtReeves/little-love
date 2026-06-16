//! Smoke test: the migration chain applies cleanly and exposes the expected
//! schema (partner link on accounts, rooms.name, invites.room_id, dropped
//! monogamy index). Migration 0009 dropped the retired is_bot/owner columns.

mod common;

#[tokio::test]
#[serial_test::serial]
async fn migrations_expose_partner_schema() {
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
    let names: std::collections::HashSet<String> = cols.into_iter().map(|(c,)| c).collect();
    assert!(
        names.contains("partner_account_id"),
        "partner_account_id should exist, got {names:?}"
    );
    assert!(
        !names.contains("is_bot") && !names.contains("owner_account_id"),
        "is_bot/owner_account_id should be dropped by migration 0009, got {names:?}"
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
