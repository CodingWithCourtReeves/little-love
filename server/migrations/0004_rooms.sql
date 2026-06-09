CREATE TABLE rooms (
  id           TEXT PRIMARY KEY,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE room_members (
  room_id     TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, account_id)
);
CREATE INDEX room_members_account_idx ON room_members (account_id);

-- Enforce monogamy: a single non-familiar room per account.
CREATE UNIQUE INDEX room_members_one_per_account ON room_members (account_id);
