-- Day-1 messages.from_user / to_user are replaced by room-membership routing.
-- Old rows are unrecoverable (no account_id mapping); truncate.
TRUNCATE TABLE messages;

ALTER TABLE messages ADD COLUMN room_id TEXT NOT NULL REFERENCES rooms(id);
ALTER TABLE messages ADD COLUMN from_account_id BIGINT NOT NULL REFERENCES accounts(id);
ALTER TABLE messages DROP COLUMN to_user;
ALTER TABLE messages DROP COLUMN from_user;
-- v0.2 uses ULID (text) for message ids, not uuid.
ALTER TABLE messages ALTER COLUMN id TYPE TEXT;
CREATE INDEX messages_room_ts_idx ON messages (room_id, ts);
