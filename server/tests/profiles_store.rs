//! Integration: the `account_profiles` upsert/read helpers round-trip the latest
//! opaque envelope + avatar key. The server treats `envelope` as opaque bytes.

use littlelove_api::attachments::insert_attachment;
use littlelove_api::profiles::{profile_for_account, upsert_profile};

mod common;

#[tokio::test]
#[serial_test::serial]
async fn upsert_then_read_roundtrips_latest() {
    let store = common::fresh_store().await;
    let (court_id, _kait_id, room_id) = common::seed_couple_room(&store).await;
    let pool = store.pool();

    // Absent → None.
    assert!(profile_for_account(pool, court_id).await.unwrap().is_none());

    // Insert with no avatar.
    upsert_profile(pool, court_id, b"env-1", None)
        .await
        .unwrap();
    let got = profile_for_account(pool, court_id).await.unwrap().unwrap();
    assert_eq!(got.envelope, b"env-1");
    assert_eq!(got.avatar_key, None);

    // Update replaces the envelope and sets avatar_key. The FK to attachments
    // requires a real blob row first.
    insert_attachment(pool, "01JBLOBKEY", &room_id, court_id, 1234)
        .await
        .unwrap();
    upsert_profile(pool, court_id, b"env-2", Some("01JBLOBKEY"))
        .await
        .unwrap();
    let got = profile_for_account(pool, court_id).await.unwrap().unwrap();
    assert_eq!(got.envelope, b"env-2");
    assert_eq!(got.avatar_key.as_deref(), Some("01JBLOBKEY"));
}

/// Deleting the room an avatar blob lives in (what `leave_room` does when the
/// last member leaves) must NOT be blocked by a profile referencing that blob.
/// The `avatar_key` FK is `ON DELETE SET NULL` (migration 0014), so the cascade
/// from rooms → attachments nulls the reference instead of raising an FK error.
#[tokio::test]
#[serial_test::serial]
async fn deleting_the_avatar_room_nulls_avatar_key_not_blocks() {
    let store = common::fresh_store().await;
    let (court_id, _kait_id, room_id) = common::seed_couple_room(&store).await;
    let pool = store.pool();

    insert_attachment(pool, "AVBLOB", &room_id, court_id, 10)
        .await
        .unwrap();
    upsert_profile(pool, court_id, b"env", Some("AVBLOB"))
        .await
        .unwrap();

    // Without ON DELETE SET NULL this DELETE fails with an FK violation and the
    // whole leave_room transaction aborts.
    sqlx::query("DELETE FROM rooms WHERE id = $1")
        .bind(&room_id)
        .execute(pool)
        .await
        .expect("deleting the avatar's room must not be blocked by the profile FK");

    // The profile survives; only the (now-deleted) blob reference is nulled.
    let got = profile_for_account(pool, court_id).await.unwrap().unwrap();
    assert_eq!(got.envelope, b"env");
    assert_eq!(got.avatar_key, None);
}
