//! Monogamy + partner link + bot ownership helpers (spec §3, §5.1).

mod common;

use littlelove_api::rooms::{bot_owned_by, monogamy_check, set_partner_link, MonogamyError};

#[tokio::test]
#[serial_test::serial]
async fn monogamy_check_allows_null_pair() {
    let store = common::fresh_store().await;
    let (a, b) = common::seed_two_humans(&store).await;
    assert!(monogamy_check(store.pool(), a, b).await.unwrap().is_ok());
}

#[tokio::test]
#[serial_test::serial]
async fn monogamy_check_accepts_already_paired_couple() {
    let store = common::fresh_store().await;
    let (a, b) = common::seed_two_humans(&store).await;
    set_partner_link(store.pool(), a, b).await.unwrap();
    assert!(monogamy_check(store.pool(), a, b).await.unwrap().is_ok());
}

#[tokio::test]
#[serial_test::serial]
async fn monogamy_check_rejects_third_human() {
    let store = common::fresh_store().await;
    let (a, b, c) = common::seed_three_humans(&store).await;
    set_partner_link(store.pool(), a, b).await.unwrap();
    let err = monogamy_check(store.pool(), a, c)
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(err, MonogamyError::WrongPartner);
}

#[tokio::test]
#[serial_test::serial]
async fn set_partner_link_is_idempotent() {
    let store = common::fresh_store().await;
    let (a, b) = common::seed_two_humans(&store).await;
    set_partner_link(store.pool(), a, b).await.unwrap();
    set_partner_link(store.pool(), a, b).await.unwrap();
    let (pa,): (Option<i64>,) =
        sqlx::query_as("SELECT partner_account_id FROM accounts WHERE id = $1")
            .bind(a)
            .fetch_one(store.pool())
            .await
            .unwrap();
    assert_eq!(pa, Some(b));
}

#[tokio::test]
#[serial_test::serial]
async fn bot_owned_by_recognises_owner_and_partner() {
    let store = common::fresh_store().await;
    let (court, kait, garden_bot, _room) = common::seed_couple_plus_bot(&store).await;
    assert!(bot_owned_by(store.pool(), garden_bot, court).await.unwrap());
    assert!(bot_owned_by(store.pool(), garden_bot, kait).await.unwrap());
}

#[tokio::test]
#[serial_test::serial]
async fn bot_owned_by_rejects_stranger() {
    let store = common::fresh_store().await;
    let (_court, _kait, garden_bot, _room) = common::seed_couple_plus_bot(&store).await;
    let (stranger,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('riley', $1, $2) RETURNING id",
    )
    .bind(vec![40u8; 32])
    .bind(vec![41u8; 32])
    .fetch_one(store.pool())
    .await
    .unwrap();
    assert!(!bot_owned_by(store.pool(), garden_bot, stranger)
        .await
        .unwrap());
}
