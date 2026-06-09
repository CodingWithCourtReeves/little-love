-- server/migrations/0002_accounts.sql
CREATE TABLE accounts (
  id            BIGSERIAL PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  ed25519_pub   BYTEA NOT NULL,
  x25519_pub    BYTEA NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX accounts_username_idx ON accounts (username);
