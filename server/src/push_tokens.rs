//! Persistence for APNs device push tokens. One row per (account, device);
//! re-registering a device upserts its current token + environment.

use sqlx::PgPool;

#[derive(Debug, Clone)]
pub struct DeviceToken {
    pub apns_token: String,
    pub environment: String,
}

/// Insert or refresh the token for one (account, device). Idempotent: a second
/// call for the same device updates the token, environment, and timestamp.
pub async fn upsert_token(
    pool: &PgPool,
    account_id: i64,
    device_id: &str,
    apns_token: &str,
    environment: &str,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO device_push_tokens (account_id, device_id, apns_token, environment, updated_at)
         VALUES ($1, $2, $3, $4, now())
         ON CONFLICT (account_id, device_id)
         DO UPDATE SET apns_token = EXCLUDED.apns_token,
                       environment = EXCLUDED.environment,
                       updated_at = now()",
    )
    .bind(account_id)
    .bind(device_id)
    .bind(apns_token)
    .bind(environment)
    .execute(pool)
    .await?;
    Ok(())
}

/// Remove a device's token (explicit unregister / logout).
pub async fn delete_token(pool: &PgPool, account_id: i64, device_id: &str) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM device_push_tokens WHERE account_id = $1 AND device_id = $2")
        .bind(account_id)
        .bind(device_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Token hygiene: APNs reports a token as dead by its value, not device id.
pub async fn delete_token_value(
    pool: &PgPool,
    account_id: i64,
    apns_token: &str,
) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM device_push_tokens WHERE account_id = $1 AND apns_token = $2")
        .bind(account_id)
        .bind(apns_token)
        .execute(pool)
        .await?;
    Ok(())
}

/// All registered tokens for an account (across the human's devices).
pub async fn tokens_for_account(
    pool: &PgPool,
    account_id: i64,
) -> anyhow::Result<Vec<DeviceToken>> {
    let rows = sqlx::query_as::<_, (String, String)>(
        "SELECT apns_token, environment FROM device_push_tokens WHERE account_id = $1",
    )
    .bind(account_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(apns_token, environment)| DeviceToken {
            apns_token,
            environment,
        })
        .collect())
}
