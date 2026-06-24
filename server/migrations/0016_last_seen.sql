-- Last time an account had an active WebSocket session, stamped on connect and
-- on the account's last disconnect. Nullable: an account that has never
-- connected (or connected before this column existed) has no value, and the
-- client renders a graceful fallback. Schema-only — no backfill.
ALTER TABLE accounts ADD COLUMN last_seen_at timestamptz;
