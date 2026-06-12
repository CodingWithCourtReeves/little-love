-- v0.3: group rooms with familiars.
-- Migration 0006 is stop-the-world (spec §10.1). v0.2 clients are rejected
-- after deploy; both human clients must be on v0.3 before this runs.

-- accounts: bot flag + ownership + canonical partner link (spec §3).
ALTER TABLE accounts
  ADD COLUMN is_bot              BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN owner_account_id    BIGINT  REFERENCES accounts(id) ON DELETE CASCADE,
  ADD COLUMN partner_account_id  BIGINT  REFERENCES accounts(id) ON DELETE SET NULL;

ALTER TABLE accounts
  ADD CONSTRAINT accounts_partner_not_self
    CHECK (partner_account_id IS NULL OR partner_account_id <> id);

ALTER TABLE accounts
  ADD CONSTRAINT accounts_owner_only_for_bots
    CHECK ((is_bot AND owner_account_id IS NOT NULL)
        OR (NOT is_bot AND owner_account_id IS NULL));

ALTER TABLE accounts
  ADD CONSTRAINT accounts_bots_no_partner
    CHECK (NOT is_bot OR partner_account_id IS NULL);

CREATE INDEX accounts_owner_idx   ON accounts(owner_account_id);
CREATE INDEX accounts_partner_idx ON accounts(partner_account_id);

-- Backstops the app-layer monogamy check (rooms::set_partner_link). Two
-- concurrent ConsumeInvites racing on the same user can both pass the app
-- check, but only one can land the row update; the other 409s on this index.
CREATE UNIQUE INDEX accounts_partner_unique
  ON accounts(partner_account_id)
  WHERE partner_account_id IS NOT NULL;

-- rooms: optional display name. Empty string means the client derives the
-- name from member roles (spec §7.1).
ALTER TABLE rooms
  ADD COLUMN name TEXT NOT NULL DEFAULT '',
  ADD CONSTRAINT rooms_name_length CHECK (char_length(name) <= 64);

-- room_members: drop v0.2 monogamy index; partner check moves to app layer
-- (server::rooms::monogamy_check) so the same couple can be in multiple
-- rooms together.
DROP INDEX room_members_one_per_account;

-- invites: bind to parent room created by CreateRoom (spec §5.2). Legacy
-- CreateInvite leaves this NULL; the consume handler lazily creates a
-- couple-only room on the fly to preserve the v0.2 pair flow.
ALTER TABLE invites
  ADD COLUMN room_id TEXT REFERENCES rooms(id) ON DELETE CASCADE;

-- messages: switch from one-row-per-message to one-row-per-recipient
-- (spec §6.2). The recipient column is initially nullable so we can
-- backfill before flipping NOT NULL.
ALTER TABLE messages
  ADD COLUMN recipient_account_id BIGINT REFERENCES accounts(id) ON DELETE CASCADE;

-- Backfill: for each existing v0.2 row, the recipient is the room member
-- who isn't the sender. v0.2's room_members_one_per_account unique index
-- guaranteed exactly one other member per room, so LIMIT 1 is unambiguous.
UPDATE messages m
SET recipient_account_id = (
  SELECT rm.account_id
  FROM room_members rm
  WHERE rm.room_id = m.room_id
    AND rm.account_id <> m.from_account_id
  LIMIT 1
)
WHERE recipient_account_id IS NULL;

-- Preflight: refuse to flip NOT NULL if any orphan rows would block it. The
-- backfill above misses rows whose room has been deleted or whose only other
-- member has left. Without this, the migration would wedge mid-transaction
-- after the schema add already committed, leaving the column nullable forever.
DO $$
DECLARE orphan_count BIGINT;
BEGIN
  SELECT COUNT(*) INTO orphan_count FROM messages WHERE recipient_account_id IS NULL;
  IF orphan_count > 0 THEN
    RAISE EXCEPTION 'migration 0006: % messages row(s) have NULL recipient_account_id after backfill; clean these up before re-running', orphan_count;
  END IF;
END $$;

ALTER TABLE messages
  ALTER COLUMN recipient_account_id SET NOT NULL;

-- v0.2 had PK on messages.id alone. In v0.3 the same logical message has
-- N rows (one per recipient), so the PK becomes composite.
ALTER TABLE messages
  DROP CONSTRAINT messages_pkey,
  ADD PRIMARY KEY (id, recipient_account_id);

CREATE INDEX messages_room_recipient_idx
  ON messages(room_id, recipient_account_id, id);

-- Backfill partner_account_id from existing 2-human couple rooms.
UPDATE accounts a
SET partner_account_id = (
  SELECT b.id
  FROM room_members rm_a
  JOIN room_members rm_b ON rm_b.room_id = rm_a.room_id AND rm_b.account_id <> rm_a.account_id
  JOIN accounts b        ON b.id = rm_b.account_id
  WHERE rm_a.account_id = a.id
    AND b.is_bot = FALSE
  LIMIT 1
)
WHERE a.is_bot = FALSE AND a.partner_account_id IS NULL;
