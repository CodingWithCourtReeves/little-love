-- Deleting a channel (DeleteRoom) removes the room row and expects everything
-- hanging off it to go too. Every other reference to rooms already cascades
-- (room_members, invites, attachments), but messages.room_id was added in 0005
-- with the default NO ACTION, so deleting any room that had a message failed on
-- messages_room_id_fkey. Re-create the constraint with ON DELETE CASCADE.
-- Schema-only: no rows are read or written here.
ALTER TABLE messages
  DROP CONSTRAINT messages_room_id_fkey,
  ADD CONSTRAINT messages_room_id_fkey
    FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE;
