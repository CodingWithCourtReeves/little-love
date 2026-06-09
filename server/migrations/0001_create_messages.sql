-- server/migrations/0001_create_messages.sql
CREATE TABLE messages (
  id          uuid        PRIMARY KEY,
  from_user   text        NOT NULL,
  to_user     text        NOT NULL,
  body        text        NOT NULL,
  ts          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_to_ts ON messages (to_user, ts);
