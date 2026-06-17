-- APNs device tokens, one row per (account, device). Schema-only: no backfill.
CREATE TABLE device_push_tokens (
  account_id   BIGINT      NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    TEXT        NOT NULL,
  apns_token   TEXT        NOT NULL,
  environment  TEXT        NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);

CREATE INDEX device_push_tokens_account_idx ON device_push_tokens (account_id);
