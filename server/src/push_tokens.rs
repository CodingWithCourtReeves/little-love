//! Persistence for APNs device push tokens. One row per (account, device);
//! re-registering a device upserts its current token + environment.

use sqlx::PgPool;

#[derive(Debug, Clone)]
pub struct DeviceToken {
    pub apns_token: String,
    pub environment: String,
}

/// Token kind: an `alert` token receives message banners; a `voip` token is a
/// PushKit token that wakes the app for an incoming call. A device registers
/// one of each.
pub const KIND_ALERT: &str = "alert";
pub const KIND_VOIP: &str = "voip";

/// Insert or refresh the token for one (account, device, kind). Idempotent: a
/// second call for the same device+kind updates the token, environment, and
/// timestamp. A device's `alert` and `voip` tokens are independent rows.
pub async fn upsert_token(
    pool: &PgPool,
    account_id: i64,
    device_id: &str,
    apns_token: &str,
    environment: &str,
    kind: &str,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO device_push_tokens (account_id, device_id, apns_token, environment, kind, updated_at)
         VALUES ($1, $2, $3, $4, $5, now())
         ON CONFLICT (account_id, device_id, kind)
         DO UPDATE SET apns_token = EXCLUDED.apns_token,
                       environment = EXCLUDED.environment,
                       updated_at = now()",
    )
    .bind(account_id)
    .bind(device_id)
    .bind(apns_token)
    .bind(environment)
    .bind(kind)
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

/// All `alert` tokens for an account (across the human's devices). Used by the
/// message-push fan-out; voip tokens are deliberately excluded so a banner push
/// never targets a PushKit token.
pub async fn tokens_for_account(
    pool: &PgPool,
    account_id: i64,
) -> anyhow::Result<Vec<DeviceToken>> {
    tokens_of_kind(pool, account_id, KIND_ALERT).await
}

/// All `voip` (PushKit) tokens for an account. Used to wake the recipient's
/// device(s) for an incoming call.
pub async fn voip_tokens_for(
    pool: &PgPool,
    account_id: i64,
) -> anyhow::Result<Vec<DeviceToken>> {
    tokens_of_kind(pool, account_id, KIND_VOIP).await
}

async fn tokens_of_kind(
    pool: &PgPool,
    account_id: i64,
    kind: &str,
) -> anyhow::Result<Vec<DeviceToken>> {
    let rows = sqlx::query_as::<_, (String, String)>(
        "SELECT apns_token, environment FROM device_push_tokens
         WHERE account_id = $1 AND kind = $2",
    )
    .bind(account_id)
    .bind(kind)
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
