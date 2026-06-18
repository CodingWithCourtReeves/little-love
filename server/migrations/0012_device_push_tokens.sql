-- APNs device tokens, one row per (account, device). Schema-only: no backfill.
-- The composite PRIMARY KEY (account_id, device_id) already provides a btree
-- with account_id leading, which serves every query here (all filter by
-- account_id first), so no separate single-column index is needed.
CREATE TABLE device_push_tokens (
  account_id   BIGINT      NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    TEXT        NOT NULL,
  apns_token   TEXT        NOT NULL,
  environment  TEXT        NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);
