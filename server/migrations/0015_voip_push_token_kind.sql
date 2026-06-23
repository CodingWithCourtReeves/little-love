-- VoIP calls need a separate PushKit token alongside the alert token, so a
-- single device now holds up to two rows distinguished by `kind`
-- ('alert' | 'voip'). Schema-only: the column DEFAULT keeps existing rows valid
-- as 'alert' without any data statement.
ALTER TABLE device_push_tokens ADD COLUMN kind TEXT NOT NULL DEFAULT 'alert';

-- Re-key on (account_id, device_id, kind) so one device can register both an
-- 'alert' and a 'voip' token. Existing rows become ('alert'), which preserves
-- the previous (account_id, device_id) uniqueness.
ALTER TABLE device_push_tokens DROP CONSTRAINT device_push_tokens_pkey;
ALTER TABLE device_push_tokens ADD PRIMARY KEY (account_id, device_id, kind);
