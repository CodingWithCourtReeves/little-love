-- v0.3: group rooms with familiars. Schema-only — no data migrations.

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
-- check, but only one can land the row update; the other 23505s on this index.
CREATE UNIQUE INDEX accounts_partner_unique
  ON accounts(partner_account_id)
  WHERE partner_account_id IS NOT NULL;

-- rooms: optional display name. Empty string means the client derives the
-- name from member roles (spec §7.1).
ALTER TABLE rooms
  ADD COLUMN name TEXT NOT NULL DEFAULT '',
  ADD CONSTRAINT rooms_name_length CHECK (char_length(name) <= 64);

-- room_members: drop v0.2 monogamy index; partner check moves to app layer
-- (server::rooms::set_partner_link with the partial UNIQUE backstop above)
-- so the same couple can be in multiple rooms together.
DROP INDEX room_members_one_per_account;

-- invites: bind to parent room created by CreateRoom (spec §5.2). Legacy
-- CreateInvite leaves this NULL; the consume handler lazily creates a
-- couple-only room on the fly to preserve the v0.2 pair flow.
ALTER TABLE invites
  ADD COLUMN room_id TEXT REFERENCES rooms(id) ON DELETE CASCADE;

-- messages: one-row-per-recipient (spec §6.2). NOT NULL from the start —
-- no data migration here. The v0.2 → v0.3 cutover predates any prod
-- traffic, so we don't carry forward v0.2 message rows.
ALTER TABLE messages
  ADD COLUMN recipient_account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE;

-- v0.2 had PK on messages.id alone. In v0.3 the same logical message has
-- N rows (one per recipient), so the PK becomes composite.
ALTER TABLE messages
  DROP CONSTRAINT messages_pkey,
  ADD PRIMARY KEY (id, recipient_account_id);

CREATE INDEX messages_room_recipient_idx
  ON messages(room_id, recipient_account_id, id);
