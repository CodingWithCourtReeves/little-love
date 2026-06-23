-- server/migrations/0013_profile.sql
-- Per-account E2EE profile (display name + avatar reference). The server stores
-- only opaque ciphertext in `envelope`; it never sees the display name or photo.
-- `avatar_key` references the attachments row holding the encrypted avatar blob,
-- whose download is authorized by room membership (couples share every room).
CREATE TABLE account_profiles (
  account_id  BIGINT      PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  envelope    BYTEA       NOT NULL,
  avatar_key  TEXT        REFERENCES attachments(blob_key),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
