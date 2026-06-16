-- server/migrations/0011_attachments.sql
-- Authorization + lifecycle ledger for E2EE blobs in R2. The server never sees
-- blob contents or the per-file key; this table only records which room a blob
-- belongs to (for download authorization) and who uploaded it.
CREATE TABLE attachments (
  blob_key            TEXT        PRIMARY KEY,
  room_id             TEXT        NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  uploader_account_id BIGINT      NOT NULL REFERENCES accounts(id),
  byte_size           BIGINT      NOT NULL,
  committed           BOOLEAN     NOT NULL DEFAULT false,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX attachments_room_idx ON attachments (room_id);
