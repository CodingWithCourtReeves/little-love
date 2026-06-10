//! Verify migration 0006 backfill logic against a seeded v0.2-shaped
//! dataset. Because the migration has already run by the time tests
//! connect, we temporarily relax the recipient NOT NULL constraint to
//! seed legacy rows, then re-apply the backfill UPDATE statements via
//! `common::apply_v0_3_backfills` and assert the post-migration state.

mod common;

#[tokio::test]
#[serial_test::serial]
async fn backfill_populates_recipient_and_partner() {
    let store = common::fresh_store().await;
    let pool = store.pool();

    // Relax the v0.3 composite PK + NOT NULL so we can seed legacy NULLs,
    // then restore them at the end of the test so subsequent tests see the
    // post-migration schema.
    sqlx::query("ALTER TABLE messages DROP CONSTRAINT messages_pkey")
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("ALTER TABLE messages ALTER COLUMN recipient_account_id DROP NOT NULL")
        .execute(pool)
        .await
        .unwrap();

    // Two humans, deterministic 32-byte pubkeys.
    let (court_id,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('court', $1, $2) RETURNING id",
    )
    .bind(vec![0u8; 32])
    .bind(vec![1u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();
    let (kaitlyn_id,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('kaitlyn', $1, $2) RETURNING id",
    )
    .bind(vec![2u8; 32])
    .bind(vec![3u8; 32])
    .fetch_one(pool)
    .await
    .unwrap();

    sqlx::query("INSERT INTO rooms (id) VALUES ('01J_legacy')")
        .execute(pool)
        .await
        .unwrap();
    for who in [court_id, kaitlyn_id] {
        sqlx::query("INSERT INTO room_members (room_id, account_id) VALUES ('01J_legacy', $1)")
            .bind(who)
            .execute(pool)
            .await
            .unwrap();
    }

    sqlx::query(
        "INSERT INTO messages (id, room_id, from_account_id, body, recipient_account_id)
         VALUES ('msg_a', '01J_legacy', $1, 'CT', NULL)",
    )
    .bind(court_id)
    .execute(pool)
    .await
    .unwrap();

    common::apply_v0_3_backfills(pool).await;

    let (rcpt,): (i64,) =
        sqlx::query_as("SELECT recipient_account_id FROM messages WHERE id='msg_a'")
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(rcpt, kaitlyn_id, "court's message should fan to kaitlyn");

    let (court_partner,): (Option<i64>,) =
        sqlx::query_as("SELECT partner_account_id FROM accounts WHERE id = $1")
            .bind(court_id)
            .fetch_one(pool)
            .await
            .unwrap();
    let (kait_partner,): (Option<i64>,) =
        sqlx::query_as("SELECT partner_account_id FROM accounts WHERE id = $1")
            .bind(kaitlyn_id)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(court_partner, Some(kaitlyn_id));
    assert_eq!(kait_partner, Some(court_id));

    // Restore the v0.3 schema so subsequent tests see the migrated state.
    sqlx::query("ALTER TABLE messages ALTER COLUMN recipient_account_id SET NOT NULL")
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("ALTER TABLE messages ADD PRIMARY KEY (id, recipient_account_id)")
        .execute(pool)
        .await
        .unwrap();
}
