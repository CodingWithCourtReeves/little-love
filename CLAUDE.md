# little-love — project rules

## Database migrations

**Migrations are schema-only. Never put data UPDATE/INSERT/DELETE statements
in a migration file.**

- `ALTER TABLE`, `CREATE INDEX`, `DROP INDEX`, `ADD CONSTRAINT`, etc. — fine.
- `UPDATE … SET …`, `INSERT INTO …`, backfills, data inspection (`DO $$ …
  RAISE EXCEPTION` blocks that read row counts), etc. — not allowed.

If a column needs values populated before a `NOT NULL` flip, either:
1. Add the column `NOT NULL` from the start (only works on empty tables),
   or
2. Land the column nullable in one migration, ship a code-level backfill
   job, then flip `NOT NULL` in a follow-up migration once you've
   confirmed no NULLs remain.

Why: data migrations are hard to reason about, hard to roll back, hard to
test, and entangle schema state with application state. Keep them
separate.
