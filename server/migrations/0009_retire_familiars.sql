-- Retire familiars/bots. Schema-only — no data migrations.
--
-- Removes the bot account flag, bot ownership link, the bot-delete challenge
-- table, and the invite `kind` discriminator. The canonical human partner
-- link (partner_account_id) and its constraints/indexes are kept: the product
-- is now couples-first 1:1 with channels, all E2EE.

-- invites: collapse back to a single (partner-only) invite kind.
ALTER TABLE invites
  DROP CONSTRAINT invites_kind_valid,
  DROP COLUMN kind;

-- Per-(owner, bot_label) bot-delete challenge nonces (and their index).
DROP TABLE bot_delete_challenges;

-- accounts: drop the bot flag + ownership link and their constraints/index.
ALTER TABLE accounts
  DROP CONSTRAINT accounts_owner_only_for_bots,
  DROP CONSTRAINT accounts_bots_no_partner;

DROP INDEX accounts_owner_idx;

ALTER TABLE accounts
  DROP COLUMN is_bot,
  DROP COLUMN owner_account_id;
