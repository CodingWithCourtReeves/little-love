-- v0.3 familiar ownership via invites. Schema-only — no data migrations.
--
-- 'partner' invites pair two humans (existing behavior). 'familiar' invites
-- (added with this column) confer bot ownership: on consume, the consuming
-- account is flipped to is_bot=TRUE owned by the inviter and seated in a 1:1
-- room. NOT NULL is safe here because the DEFAULT populates any existing rows
-- without a data statement.
ALTER TABLE invites
  ADD COLUMN kind TEXT NOT NULL DEFAULT 'partner',
  ADD CONSTRAINT invites_kind_valid CHECK (kind IN ('partner', 'familiar'));
