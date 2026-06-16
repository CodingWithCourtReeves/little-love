//! Concurrency tests around the v0.3 monogamy invariant.
//!
//! These exercise the property that two parallel attempts to pair the same
//! user with different peers cannot both succeed — neither at the app layer
//! (set_partner_link's FOR UPDATE check+write) nor at the DB layer (the
//! partial UNIQUE(partner_account_id) backstop).

mod common;

use futures::future::join_all;
use littlelove_api::rooms::{set_partner_link, MonogamyError, PairError};

#[tokio::test]
#[serial_test::serial]
async fn parallel_pair_attempts_only_one_wins() {
    let store = common::fresh_store().await;
    let (court, kait, riley) = common::seed_three_humans(&store).await;
    let pool = store.pool().clone();

    let p1 = pool.clone();
    let p2 = pool.clone();
    let h1 = tokio::spawn(async move { set_partner_link(&p1, court, kait).await });
    let h2 = tokio::spawn(async move { set_partner_link(&p2, court, riley).await });
    let (r1, r2) = (h1.await.unwrap(), h2.await.unwrap());

    let ok_count = [r1.is_ok(), r2.is_ok()].iter().filter(|b| **b).count();
    assert_eq!(
        ok_count, 1,
        "exactly one of the racing pair attempts must succeed"
    );

    let (count,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM accounts WHERE id = $1 AND partner_account_id IS NOT NULL",
    )
    .bind(court)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1, "court must have exactly one partner");
}

#[tokio::test]
#[serial_test::serial]
async fn set_partner_link_rejects_third_human() {
    let store = common::fresh_store().await;
    let (a, b, c) = common::seed_three_humans(&store).await;
    set_partner_link(store.pool(), a, b).await.unwrap();
    let err = set_partner_link(store.pool(), a, c).await.unwrap_err();
    assert!(
        matches!(err, PairError::Monogamy(MonogamyError::WrongPartner)),
        "expected WrongPartner, got {err:?}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn partial_unique_index_backstops_app_check() {
    // Direct DB-level proof: even if the app check were bypassed, the
    // partial UNIQUE index would refuse the second write.
    let store = common::fresh_store().await;
    let (a, b, c) = common::seed_three_humans(&store).await;
    sqlx::query("UPDATE accounts SET partner_account_id = $2 WHERE id = $1")
        .bind(a)
        .bind(b)
        .execute(store.pool())
        .await
        .unwrap();
    let err = sqlx::query("UPDATE accounts SET partner_account_id = $2 WHERE id = $1")
        .bind(c)
        .bind(b)
        .execute(store.pool())
        .await
        .unwrap_err();
    match err {
        sqlx::Error::Database(db) => {
            assert_eq!(
                db.code().as_deref(),
                Some("23505"),
                "expected unique_violation"
            );
        }
        other => panic!("expected unique_violation Database error, got {other:?}"),
    }
}

#[tokio::test]
#[serial_test::serial]
async fn many_parallel_pair_attempts_still_resolve_to_one_winner() {
    // Tighter stress: 8 parallel attempts pairing court with 8 different
    // peers. Exactly one must win; court must end with exactly one partner;
    // the partner row must match the winning peer.
    let store = common::fresh_store().await;
    let pool = store.pool().clone();

    let (court,): (i64,) = sqlx::query_as(
        "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
         VALUES ('court', $1, $2) RETURNING id",
    )
    .bind(vec![10u8; 32])
    .bind(vec![11u8; 32])
    .fetch_one(&pool)
    .await
    .unwrap();

    let mut peers = Vec::new();
    for i in 0..8u8 {
        let username = format!("peer{i}");
        let (id,): (i64,) = sqlx::query_as(
            "INSERT INTO accounts (username, ed25519_pub, x25519_pub)
             VALUES ($1, $2, $3) RETURNING id",
        )
        .bind(&username)
        .bind(vec![20 + i; 32])
        .bind(vec![21 + i; 32])
        .fetch_one(&pool)
        .await
        .unwrap();
        peers.push(id);
    }

    let handles: Vec<_> = peers
        .iter()
        .copied()
        .map(|p| {
            let pool = pool.clone();
            tokio::spawn(async move { (p, set_partner_link(&pool, court, p).await) })
        })
        .collect();
    let results = join_all(handles).await;

    let winners: Vec<i64> = results
        .into_iter()
        .filter_map(|r| {
            let (peer, outcome) = r.unwrap();
            outcome.is_ok().then_some(peer)
        })
        .collect();
    assert_eq!(winners.len(), 1, "exactly one winner, got {winners:?}");

    let (partner,): (Option<i64>,) =
        sqlx::query_as("SELECT partner_account_id FROM accounts WHERE id = $1")
            .bind(court)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(partner, Some(winners[0]));
}
