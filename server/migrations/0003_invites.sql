CREATE TABLE invites (
  token_hash   BYTEA PRIMARY KEY,
  inviter_id   BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at   TIMESTAMPTZ NOT NULL,
  consumed_at  TIMESTAMPTZ
);
CREATE INDEX invites_inviter_idx ON invites (inviter_id) WHERE consumed_at IS NULL;
