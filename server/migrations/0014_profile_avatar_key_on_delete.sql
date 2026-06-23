-- server/migrations/0014_profile_avatar_key_on_delete.sql
-- account_profiles.avatar_key referenced attachments(blob_key) with the default
-- ON DELETE NO ACTION. Because attachments.room_id cascades on room deletion,
-- deleting a room (e.g. leave_room when the last member leaves) tries to delete
-- the room's attachment rows — but the profile's avatar_key reference RESTRICTs
-- that delete, failing the whole transaction.
--
-- Switch to ON DELETE SET NULL: dropping the avatar blob simply nulls the
-- reference. The encrypted envelope still decodes and the partner falls back to
-- initials. Schema-only.
ALTER TABLE account_profiles
  DROP CONSTRAINT account_profiles_avatar_key_fkey,
  ADD CONSTRAINT account_profiles_avatar_key_fkey
    FOREIGN KEY (avatar_key) REFERENCES attachments (blob_key) ON DELETE SET NULL;
