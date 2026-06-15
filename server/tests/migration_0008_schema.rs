//! Smoke test: migration 0008 applies cleanly and adds invites.kind
//! (text, NOT NULL, default 'partner').

mod common;

#[tokio::test]
#[serial_test::serial]
async fn migration_0008_adds_invites_kind() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    // Change B: narrow the introspection query to public schema so a hypothetical
    // shadowing table in another schema cannot produce a false positive.
    let col: Option<(String, String, Option<String>)> = sqlx::query_as(
        "SELECT column_name, is_nullable, column_default
         FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name='invites' AND column_name='kind'",
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

/// Change A: verify the CHECK constraint `invites_kind_valid` actually fires
/// and that the database error message names the constraint.
#[tokio::test]
#[serial_test::serial]
async fn migration_0008_check_rejects_invalid_kind() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    // Seed one account to satisfy the inviter_id FK.
    let (inviter_id, _) = common::seed_two_humans(&store).await;

    // Attempt to INSERT a row with an invalid kind value.
    // Required NOT NULL columns (from migrations 0003 + 0008):
    //   token_hash  BYTEA        PRIMARY KEY
    //   inviter_id  BIGINT       NOT NULL REFERENCES accounts(id)
    //   expires_at  TIMESTAMPTZ  NOT NULL
    //   kind        TEXT         NOT NULL DEFAULT 'partner'
    // Nullable columns omitted: consumed_at, room_id.
    let result = sqlx::query(
        "INSERT INTO invites (token_hash, inviter_id, expires_at, kind) \
         VALUES ($1, $2, NOW() + INTERVAL '1 day', 'invalid')",
    )
    .bind(vec![0u8; 32])
    .bind(inviter_id)
    .execute(pool)
    .await;

    assert!(result.is_err(), "CHECK should reject kind='invalid'");
    assert!(
        result.unwrap_err().to_string().contains("invites_kind_valid"),
        "error should mention the constraint name 'invites_kind_valid'",
    );
}
