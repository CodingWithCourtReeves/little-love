//! Monogamy + partner link helpers (spec §3, §5.1).

mod common;

use littlelove_api::rooms::{monogamy_check, set_partner_link, MonogamyError};

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
