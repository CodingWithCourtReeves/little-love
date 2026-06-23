//! DB helpers for the `account_profiles` ledger (migration 0013). Each account
//! has at most one profile row holding an opaque E2EE `envelope` (display name +
//! avatar descriptor, sealed with the couple's pairwise key) plus the avatar's
//! blob key for download authorization. The server never decodes `envelope`.
use chrono::{DateTime, Utc};
use sqlx::PgPool;

#[derive(Debug, Clone)]
pub struct StoredProfile {
    pub envelope: Vec<u8>,
    pub avatar_key: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// Insert or replace the caller's profile. Server stores `envelope` opaquely.
pub async fn upsert_profile(
    pool: &PgPool,
    account_id: i64,
    envelope: &[u8],
    avatar_key: Option<&str>,
) -> sqlx::Result<()> {
    sqlx::query(
        "INSERT INTO account_profiles (account_id, envelope, avatar_key, updated_at)
         VALUES ($1, $2, $3, now())
         ON CONFLICT (account_id)
         DO UPDATE SET envelope = EXCLUDED.envelope,
                       avatar_key = EXCLUDED.avatar_key,
                       updated_at = now()",
    )
    .bind(account_id)
    .bind(envelope)
    .bind(avatar_key)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn profile_for_account(
    pool: &PgPool,
    account_id: i64,
) -> sqlx::Result<Option<StoredProfile>> {
    let row = sqlx::query_as::<_, (Vec<u8>, Option<String>, DateTime<Utc>)>(
        "SELECT envelope, avatar_key, updated_at FROM account_profiles WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(envelope, avatar_key, updated_at)| StoredProfile {
        envelope,
        avatar_key,
        updated_at,
    }))
}
