-- Per-(owner, bot_label) challenge nonces backing the bot-delete protocol.
-- A POST /accounts/bot/{label}/delete-challenge issues a fresh nonce and
-- upserts the row; DELETE /accounts/bot/{label} consumes it. The composite
-- PK ensures only the most recent challenge is live for any (owner, label).
CREATE TABLE bot_delete_challenges (
    owner_account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    bot_label        TEXT   NOT NULL,
    nonce            BYTEA  NOT NULL,
    expires_at       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (owner_account_id, bot_label)
);

CREATE INDEX bot_delete_challenges_expires_at_idx
    ON bot_delete_challenges (expires_at);
