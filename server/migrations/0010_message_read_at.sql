-- Read receipts (double hearts). Schema-only: nullable column, no backfill.
-- A message you sent is "read" once the partner's row for that id has read_at
-- set. Couples-only, so there is exactly one other recipient row per message.
ALTER TABLE messages ADD COLUMN read_at timestamptz;

-- Supports the mark-read range UPDATE (recipient's unread rows in a room,
-- id <= watermark) and the replay read-state lookup.
CREATE INDEX messages_recipient_unread_idx
  ON messages (recipient_account_id, room_id, id)
  WHERE read_at IS NULL;
