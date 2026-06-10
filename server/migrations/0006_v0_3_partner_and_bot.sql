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
