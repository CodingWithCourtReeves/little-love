use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::wire::MsgPayload;

#[derive(Debug, Clone)]
pub struct MessageRow {
    pub id: Uuid,
    pub from_user: String,
    pub to_user: String,
    pub body: String,
    pub ts: DateTime<Utc>,
}

impl From<MsgPayload> for MessageRow {
    fn from(m: MsgPayload) -> Self {
        Self {
            id: m.id,
            from_user: m.from,
            to_user: m.to,
            body: m.body,
            ts: m.ts,
        }
    }
}

impl MessageRow {
    pub fn into_payload(self, replayed: bool) -> MsgPayload {
        MsgPayload {
            id: self.id,
            from: self.from_user,
            to: self.to_user,
            body: self.body,
            ts: self.ts,
            replayed,
        }
    }
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
}

impl Store {
    pub async fn connect(database_url: &str) -> anyhow::Result<Self> {
        let pool = PgPool::connect(database_url).await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn insert(&self, row: MessageRow) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO messages (id, from_user, to_user, body, ts)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(row.id)
        .bind(row.from_user)
        .bind(row.to_user)
        .bind(row.body)
        .bind(row.ts)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn messages_for(
        &self,
        recipient: &str,
        since: DateTime<Utc>,
    ) -> anyhow::Result<Vec<MessageRow>> {
        let rows = sqlx::query_as::<_, (Uuid, String, String, String, DateTime<Utc>)>(
            "SELECT id, from_user, to_user, body, ts
             FROM messages
             WHERE to_user = $1 AND ts > $2
             ORDER BY ts ASC",
        )
        .bind(recipient)
        .bind(since)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|(id, from_user, to_user, body, ts)| MessageRow {
                id,
                from_user,
                to_user,
                body,
                ts,
            })
            .collect())
    }
}
