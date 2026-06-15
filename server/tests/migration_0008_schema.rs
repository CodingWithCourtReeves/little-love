//! Smoke test: migration 0008 applies cleanly and adds invites.kind
//! (text, NOT NULL, default 'partner').

mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_0008_adds_invites_kind() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    let col: Option<(String, String, Option<String>)> = sqlx::query_as(
        "SELECT column_name, is_nullable, column_default
         FROM information_schema.columns
         WHERE table_name='invites' AND column_name='kind'",
    )
    .fetch_optional(pool)
    .await
    .unwrap();

    let (name, is_nullable, default) = col.expect("invites.kind missing");
    assert_eq!(name, "kind");
    assert_eq!(is_nullable, "NO", "invites.kind should be NOT NULL");
    assert!(
        default.unwrap_or_default().contains("partner"),
        "invites.kind should default to 'partner'"
    );
}
