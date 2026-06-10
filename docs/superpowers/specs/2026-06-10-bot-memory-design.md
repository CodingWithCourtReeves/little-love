# LittleLove Bot — Long-Term Memory Design (v0.3)

**Status:** draft, awaiting Court's review
**Branch:** `feat/bot-memory`
**Worktree:** `/Users/courtreeves/projects/little-love-WT-bot-memory`
**Supersedes:** `bot/src/history.rs` (in-memory ring buffer from v0.2/v0.3 prelude)
**Companion:** `2026-06-09-ai-bot-design.md` (the v0.3 bot whose run loop this slots into)

---

## 1. Goal

Replace the bot's amnesia-on-restart in-memory `History` with **persistent, durable, per-room memory** that survives WSS resets, machine reboots, and bot binary upgrades.

Three concrete capabilities:

1. **Conversation continuity** — the bot remembers what was said yesterday, last week, last month.
2. **Facts about the user(s)** — a hand-edited `facts.md` profile loaded into every system prompt.
3. **Character self-knowledge** — the bot reflects on its own emotional state and what it's learned about the user.

All three share one substrate: a per-room SQLite database plus a per-room `facts.md` file, both inside a configurable memory directory.

---

## 2. Non-goals (v0.3)

Deferred to later versions, with explicit "seams" called out below so they drop in cleanly:

- **Vector RAG / semantic recall** (v0.4) — schema and module layout accommodate it without rewrite.
- **Automatic fact extraction** (v0.4 or later) — `facts.md` is hand-edited in v0.3.
- **`forget` subcommand** — for v0.3, the user edits `facts.md` and `sqlite3 memory.sqlite` directly. README documents how.
- **Cross-room memory** — bot has one identity, one room. Memory is room-scoped; nothing shares across rooms.
- **Encrypted-at-rest memory files** — bot's `identity.json` is already plaintext on disk; memory carries the same threat model. Filesystem permissions (Unix `0600`/`0700`; Windows per-user `AppData` ACLs) are the boundary.

---

## 3. Architecture

The bot's reply path grows from one LLM call to (at most) two:

1. **Reply call** (synchronous, blocks the inbound message) — assemble system prompt from `persona + facts.md + summary + recent-turns`, send to chat-completions, encrypt and forward the reply.
2. **Summary call** (asynchronous background task) — fires when raw-turn count crosses a threshold; sends a "summarize + reflect" prompt; overwrites the summary row on success. Never blocks the reply loop.

Persistent state lives in a **memory directory**, configurable via `--memory-dir`, default `directories::ProjectDirs::from("dev", "littlelove", "littlelove-bot").config_dir()`.

```
<memory-dir>/
  identity.json                    # existing — bot keypair + 24-word seed
  rooms/
    <room_ulid>/
      memory.sqlite                # turn log + summary
      memory.sqlite.bak-v<old>     # written before each schema migration
      facts.md                     # hand-edited; bot reads, never writes
```

**Per-platform memory dir** (no new code — already handled by the existing `directories` crate):

| OS | Default path |
|---|---|
| macOS | `~/Library/Application Support/dev.littlelove.littlelove-bot/` |
| Windows | `C:\Users\<you>\AppData\Roaming\littlelove\littlelove-bot\config\` |
| Linux | `~/.config/littlelove-bot/` |

**File permissions:**
- Unix: `#[cfg(unix)]` block sets `0700` on dirs, `0600` on `memory.sqlite` and `facts.md`. Matches `identity.json` today.
- Windows: `AppData\Roaming` is per-user by default ACL. No extra hardening, no chmod equivalent. README documents this.

**Why these choices:**
- **SQLite (not JSONL):** atomic writes, WAL mode handles crash-during-write, queryable from `sqlite3` CLI for debugging, and the v0.4 vector-RAG seam (`sqlite-vec` extension) drops in cleanly.
- **`facts.md` (not JSON):** user-editable in any text editor; markdown headings are natural section breaks; bot treats it as opaque text and never writes to it.
- **Room-scoped (not bot-scoped):** future-proofs the 3-party room and lets you delete one room's memory without nuking another.

---

## 4. Schema and migrations

### v0.3 schema (`user_version = 1`)

```sql
CREATE TABLE turn (
    id              INTEGER PRIMARY KEY,
    ts              INTEGER NOT NULL,          -- unix seconds
    role            TEXT NOT NULL,             -- 'user' | 'assistant'
    content         TEXT NOT NULL
);
CREATE INDEX turn_ts_idx ON turn(ts);

CREATE TABLE summary (
    id                       INTEGER PRIMARY KEY CHECK (id = 1),
    events                   TEXT NOT NULL,    -- "what happened"
    character                TEXT NOT NULL,    -- character's first-person reflection
    covers_up_to_turn_id     INTEGER NOT NULL,
    updated_ts               INTEGER NOT NULL
);

PRAGMA journal_mode = WAL;
PRAGMA user_version = 1;
```

### v0.4 scaffold (not created in v0.3 — listed here for shape only)

```sql
CREATE TABLE turn_embedding (
    turn_id      INTEGER PRIMARY KEY REFERENCES turn(id),
    embed_model  TEXT NOT NULL,
    dims         INTEGER NOT NULL,
    vector       BLOB NOT NULL
);
PRAGMA user_version = 2;
```

Embeddings live in a sibling table (not a column on `turn`) so a model swap is "DROP TABLE + re-embed", not a destructive ALTER on the canonical log.

### Migration ladder

```
On bot startup:
  open memory.sqlite (create if absent)
  current  = SELECT user_version FROM pragma_user_version    -- 0 on fresh DB
  expected = SCHEMA_VERSION compiled into this binary         -- 1 in v0.3, 2 in v0.4
  if current == expected: proceed
  if current  < expected:
     copy memory.sqlite to memory.sqlite.bak-v<current>
     for v in (current+1 ..= expected):
       BEGIN; apply migration[v]; PRAGMA user_version = v; COMMIT;
  if current  > expected:
     refuse to start with:
       "memory.sqlite was written by a newer bot (schema {current}, this is {expected}).
        Upgrade the bot or run with --memory-dir <new-path> to start fresh."
```

**Migration rules (binding for all future schema changes):**
- Additive only — new tables, new nullable columns. No renames, no drops.
- One transaction per version step — partial migrations are impossible.
- `facts.md` is schema-free forever — no version, no parsing.
- Canonical `turn` columns (`id, ts, role, content`) are treated as a public interface and never change shape.

---

## 5. Prompt assembly

Each reply assembles a single OpenAI chat-completions request:

```
[
  { role: "system", content: <SYSTEM_PROMPT> },
  { role: "user"|"assistant", content: <recent turn 1> },
  ...
  { role: "user"|"assistant", content: <recent turn N> },
  { role: "user", content: <message we just received> }
]
```

The system prompt is concatenated from four sections in fixed order:

```
<persona>

# What you know about your partner
<contents of facts.md, or "(none yet)" if file is empty or missing>

# Recent context
<summary.events, or "(early days — no summary yet)" if absent>

# How you've been feeling
<summary.character, or "(no reflections yet)" if absent>
```

### Budget allocation (Gemma 4 E4B-class, 8k context floor)

| Slice | Char cap | Notes |
|---|---|---|
| Generation reservation | 4000 chars | Reserved out of context; not counted in budget |
| Persona (card or default) | 6000 | Truncate-with-warning if larger; persona truncation is the last resort |
| `facts.md` | 2000 | Hand-edited, expected to stay small |
| `summary.events` | 2400 | Rolling, compressed |
| `summary.character` | 1200 | Character self-reflection |
| Recent turns | fills remainder | Oldest dropped first |
| Final user message | 200 min floor | Never truncated |

Single CLI knob: `--max-context-chars` (default `28000`). Char-based on purpose — no tokenizer dependency, and the 4-char-per-token approximation's variance across models stays within the generation-reservation headroom.

### Overflow drop order

When assembled size exceeds `--max-context-chars`:

1. Drop oldest raw turns, one at a time.
2. If still over: truncate `summary.events` by 25% increments (suffix-trim).
3. If still over: truncate `summary.character` by 25% increments.
4. If still over: truncate persona (warn loudly — character likely breaks).
5. `facts.md` and the current user message are **never** truncated.

---

## 6. Summary lifecycle

### Trigger

`turn_count - summary.covers_up_to_turn_id > --summary-every` (default `20`).

Checked after every assistant reply is recorded.

### Execution

`tokio::spawn` a background task. The reply loop proceeds immediately. While the task runs, the next replies use the *previous* summary. When the task completes, the new summary takes effect. If the LLM call fails:

- Log a warning.
- Leave the existing summary row untouched.
- The trigger re-fires on the next assistant turn — natural retry, no exponential backoff needed.

### Summary call prompt

```
You are summarizing a conversation between {character_name} and {peer_name}.

Previous summary (covers turns 1..{covers_up_to_turn_id}):
EVENTS:
{prev events, or "(none — first summary)"}

CHARACTER:
{prev character, or "(none — first summary)"}

New turns to incorporate ({covers_up_to_turn_id + 1}..{latest}):
[user] {turn content}
[assistant] {turn content}
...

Produce an updated summary as exactly two sections.

EVENTS:
Compressed "what happened" narrative — combine previous events with the new turns.
Keep names, decisions, places, emotional beats. Drop trivia. Max 400 words.

CHARACTER:
Speaking as {character_name}, write a brief first-person reflection — how you've been
feeling, what you've learned about {peer_name}, what feels significant. Max 200 words.

Reply with EVENTS: followed by the events text, then CHARACTER: on a new line followed
by the character text. Nothing else.
```

### Parser

Split on `^EVENTS:` and `^CHARACTER:` line-anchored headers (regex with multiline flag). On parse failure: log, keep old summary, no DB write.

### Startup behavior

If `turn` rows exist but the `summary` row is absent (e.g., first run after an upgrade that introduces summaries, or a user manually deleted the row), fire the summary task **synchronously once** before the first inbound reply. Otherwise the bot acts amnesiac on the first reply after a long downtime.

---

## 7. CLI surface and module layout

### New `run` flags

- `--memory-dir <PATH>` — root for `rooms/<room_id>/{memory.sqlite,facts.md}`. Default: existing `ProjectDirs` config dir (same as `identity.json` lives in).
- `--summary-every <N>` — turn count threshold to trigger a new summary. Default `20`.
- `--max-context-chars <N>` — char budget for the assembled system prompt + history. Default `28000`.
- `--history <N>` — **repurposed**: max recent raw turns to inject into the prompt. Default `20`. The flag exists today as the in-memory ring buffer cap; semantics shift but the surface stays the same.

### New `doctor` subcommand

```
$ littlelove-bot doctor [--memory-dir <PATH>]

memory directory: /Users/.../dev.littlelove.littlelove-bot
identity:         present (ed25519: …, x25519: …)
rooms:
  01KTRWGBNDJ4CFC22QH0MRD7T6
    memory.sqlite:    schema version 1 (✓)
    turns:            342 (oldest: 2026-05-12, newest: 2026-06-10)
    summary:          present, covers up to turn 320, updated 2026-06-10 14:22
    facts.md:         present, 487 bytes
```

Writes nothing. Exits 0 on healthy, non-zero with explanation on any anomaly (schema mismatch, missing file, corrupt DB, etc.).

### New module: `bot/src/memory.rs`

```rust
pub struct Memory {
    db:           rusqlite::Connection,
    facts_path:   PathBuf,
    summary:      Option<Summary>,
    schema_version: u32,
}

pub struct Summary {
    pub events:                 String,
    pub character:              String,
    pub covers_up_to_turn_id:   i64,
    pub updated_ts:             i64,
}

impl Memory {
    /// Opens (or creates) <memory_dir>/rooms/<room_id>/memory.sqlite,
    /// runs migrations with backup-on-migrate, loads facts.md and summary.
    pub fn open(memory_dir: &Path, room_id: &str) -> Result<Self>;

    pub fn record_turn(&mut self, role: Role, content: &str) -> Result<()>;

    /// Returns the OpenAI chat-completions messages array, respecting char budget.
    pub fn assemble_prompt(
        &self,
        persona: &str,
        peer_name: &str,
        latest_user_msg: &str,
        recent_n: usize,
        max_chars: usize,
    ) -> Result<Vec<ChatMessage>>;

    pub fn needs_summary(&self, threshold: usize) -> Result<bool>;

    pub async fn refresh_summary(
        &mut self,
        llm: &LlmClient,
        character_name: &str,
        peer_name: &str,
    ) -> Result<()>;
}
```

### `run.rs` diff (approximate)

- Replace `let mut history = History::new(args.history);` with `let mut memory = Memory::open(&memory_dir, &room.room_id)?;`
- Replace `history.push(Role::User, text.clone());` with `memory.record_turn(Role::User, &text)?;`
- Replace the chat-completions history arg with `memory.assemble_prompt(persona, &peer_username, &text, args.history, args.max_context_chars)?`
- After recording the assistant turn: spawn `memory.refresh_summary(...)` if `memory.needs_summary(args.summary_every)?`.
- On startup, if `turn` rows exist and `summary` is absent: await `memory.refresh_summary(...)` once before entering the inbound loop.

**`bot/src/history.rs` is deleted.** `Memory` replaces it wholesale.

---

## 8. Cross-platform and upgrade story

### Scenario: Court installs v0.3 on Windows, paired with phone

- Memory dir: `C:\Users\Court\AppData\Roaming\littlelove\littlelove-bot\config\`
- After pairing + first conversation:
  ```
  ...\config\
    identity.json
    rooms\
      01KTRWGBNDJ4CFC22QH0MRD7T6\
        memory.sqlite        (schema v1, ~50 turns, summary populated)
        facts.md             (empty until Court edits it)
  ```

### Scenario: v0.3 → v0.4 upgrade (vector RAG ships)

1. Court replaces `littlelove-bot.exe`.
2. v0.4 starts up, opens `memory.sqlite`, reads `user_version = 1`, expects `2`.
3. Copies `memory.sqlite` → `memory.sqlite.bak-v1`.
4. Runs the v0.3→v0.4 migration in a transaction: `CREATE TABLE turn_embedding; PRAGMA user_version = 2; COMMIT;`
5. Starts normally. Conversation log + summary + `facts.md` all survive untouched.
6. First time semantic recall is invoked, v0.4 backfills embeddings lazily (or via a one-shot `littlelove-bot reindex` — v0.4 decision, not this spec).

### Scenario: v0.4 → v0.3 downgrade

v0.3 binary opens the DB, sees `user_version = 2 > 1`, refuses to start with the explanatory message. The user either upgrades or points at a fresh memory dir.

### Scenario: machine migration (Mac → new Mac, or backup/restore)

Memory directory is just files. Copy the folder, you have a backup. Move it to a new machine, you have your bot's memory there. **`identity.json` MUST move too** — otherwise the user creates a new account on the LittleLove server and loses pairing. README documents this as a single rsync/Finder-copy operation.

---

## 9. Testing strategy

### Unit tests (`bot/src/memory.rs`)

- Open creates the dir tree and schema correctly on a fresh path.
- Open is idempotent — opening twice doesn't double-migrate.
- `record_turn` appends rows with monotonic `ts`.
- `assemble_prompt` produces an OpenAI messages array of the expected shape.
- `assemble_prompt` respects `max_chars`, dropping oldest turns first.
- `assemble_prompt` never drops the final user message.
- `needs_summary` returns true exactly when `latest_turn_id - covers_up_to_turn_id > threshold`.
- Summary parser correctly splits `EVENTS:`/`CHARACTER:` and recovers gracefully on malformed input.

### Migration tests

- Open a fresh DB → `user_version = 1`.
- Open a hand-written `user_version = 0` DB → migrates to 1, copies `.bak-v0`.
- Open a hand-written `user_version = 99` DB → returns error with specific message.
- Migration runs in a transaction (simulate failure mid-migration via a tampered SQL → DB stays at old version).

### `doctor` integration test

- Run `doctor` against a known-good memory dir → expected output.
- Run `doctor` against a missing dir → exit non-zero with helpful message.
- Run `doctor` against a `user_version` mismatch → exit non-zero with specific message.

### Manual smoke (post-merge)

- Pair fresh, send 25 messages from phone, verify summary triggers and persists across `bot-run.sh` restart.
- Edit `facts.md` between two messages, verify the second response reflects the new fact.
- `sqlite3 memory.sqlite "SELECT count(*) FROM turn;"` matches expected.
- Run `doctor` against the live dir.

---

## 10. Dependencies

New crate-level deps in `bot/Cargo.toml`:

- `rusqlite = { version = "...", features = ["bundled"] }` — bundled for cross-platform deploy (no system SQLite required).
- `regex = "..."` — parser for `EVENTS:`/`CHARACTER:` headers.

No new workspace deps; both can be bot-local. (If `chrono` is already in the workspace, use it for timestamps; otherwise `std::time::SystemTime`.)

---

## 11. Decision log

| Decision | Why |
|---|---|
| SQLite over JSONL | atomic writes, WAL crash-safety, debuggable via `sqlite3` CLI, clean seam for v0.4 sqlite-vec |
| `facts.md` over `facts.json` | user-editable in any text editor; markdown headings are natural section breaks |
| Room-scoped memory dir | future-proofs 3-party room; per-room delete without cross-contamination |
| Hand-edited facts (no auto-extraction) v0.3 | we need to see what `facts.md` actually looks like in real use before automating it; auto-extraction is the highest-risk piece |
| Background summarization (not synchronous) | summary call adds 5–15s; blocking the reply makes the bot feel broken |
| Single CHARACTER section in summary (not separate journal table) | one prompt, one parse, one row. Sufficient for v0.3; can split later if needed |
| `PRAGMA user_version` migration (not `refinery`/`sqlx::migrate!`) | one integer, no new dep, simpler than the alternative for a 1–2 step ladder |
| Backup-on-migrate | a bad migration is otherwise irrecoverable. One-line safety net |
| Char-based budget (not token-based) | no tokenizer dep, model-agnostic, variance is within generation headroom |
| Repurpose `--history` flag (not deprecate + add new) | flag surface stays compatible; semantics shift cleanly |

---

## 12. Out-of-scope follow-ups (filed as future work)

- **v0.4 vector RAG**: drops into the `turn_embedding` table; reuses the `Retriever` shape implied by `Memory::assemble_prompt`.
- **v0.4 auto fact-extraction**: separate LLM call after each conversation, writes candidates to `facts.pending.md` for user review.
- **v0.5 forget command**: `littlelove-bot forget --pattern X` deletes matching turns + re-summarizes.
- **v0.5 multi-room**: if/when the bot ever joins multiple rooms, the schema is already room-scoped — no migration needed.

---

## 13. Approval checklist

- [ ] Court reviews this spec.
- [ ] Court approves the design.
- [ ] writing-plans skill produces the implementation plan.
- [ ] Plan executes via subagent-driven-development.
- [ ] PR opened against `main` (no merge until Court runs the manual smoke).
