# LittleLove — Local-AI Bot Client (WT-bot)

**Date:** 2026-06-09
**Status:** Drafted by WT-bot; pending Court approval.
**Predecessors:**
- `docs/positioning.md` — the brand contract this bot exists to honor.
- `docs/superpowers/specs/2026-06-09-littlelove-accounts-and-inbox-design.md` — the v0.2 protocol the bot speaks.
- `docs/superpowers/specs/2026-06-09-littlelove-design.md` — Phase 1 design where a full multi-bot host eventually lives. This bot is a deliberate vertical slice of that vision.

---

## 1. Summary

A standalone Rust binary (`littlelove-bot`) that participates in a LittleLove
room as a regular paired client and bridges that room to a local
OpenAI-compatible LLM endpoint (default `http://localhost:8080/v1`,
i.e. `llama-server`). From the server's perspective the bot is just another
account; from Court's perspective it is an AI familiar he chats with via the
existing inbox.

The bot lives in its **own** room paired to Court (or any single human
operator). It does NOT join the Court+Kaitlyn couples room — the monogamy
constraint forbids it and the positioning would forbid it even if the
constraint didn't.

Tag target: rolled into the next `v0.2.x` release after WT-D and WT-E land.

---

## 2. Goals & Non-Goals

### Goals
- One pre-built binary per OS, cross-compiled in CI, downloadable from a GitHub release.
- `bot pair --code <four-words>` consumes a LittleLove invite, completes signup, persists identity.
- `bot run` connects to the server, subscribes to its room, listens for messages, calls the local LLM, encrypts the reply, sends it back.
- The bot's persona is shaped by a Character Card v2 / v3 PNG (`--character-card`) when present, or a plain-text system prompt (`--system-prompt-file` / env / default) otherwise. Honors the `docs/positioning.md` "character cards by default" promise.
- 100% of message plaintext stays on Court's machine. The LLM endpoint is verified to be local before any request goes out.
- Crypto byte layouts match the server byte-for-byte. No second implementation.

### Non-Goals (this WT)
- Multi-room support. The bot is in exactly one room.
- Streaming responses. We send a single `Send` frame with the complete reply.
- Tool-use, function calling, image input, audio. Text in, text out.
- Voice for the bot (TTS). Defer to Phase 1.
- Conversation persistence across restarts. In-memory only.
- A multi-bot router or runtime plugin system. The brief is explicit: one bot, one model, one room.
- Cloud LLM providers of any kind — see §10.

### Positioning posture
Per `docs/positioning.md`: the bot is a familiar Court brought along, not a
feature LittleLove sells. The binary refuses to connect to non-private IP
endpoints, by code, not by config. There is no flag to disable this.

---

## 3. Crate Layout

### 3.1 Decision: factor a shared crypto crate

The bot must produce byte-identical Ed25519 signatures, X25519 shared
secrets, BIP39 invite codes, and XChaCha20-Poly1305 ciphertexts to those the
server consumes. Today these primitives live in `server/src/{auth,
invites, wordlist_bip39_en}.rs`. Two divergent implementations of the same
crypto would be a security-bug factory: one side changes a domain tag, the
other doesn't, and an attacker exploits the gap.

**Proposed change:** introduce a new workspace crate `crypto/` (crate name
`littlelove-crypto`). Move the following from `server/src/` into it:

- `auth.rs` → `littlelove-crypto::sig` (challenge_signing_input,
  invite_consume_signing_input, verify helpers, NONCE_LEN, both DOMAIN_TAG
  constants).
- `invites.rs` → split. The pure-crypto bits (BIP39 encode/decode,
  canonical token, sha256, generate_invite, wordlist) move to
  `littlelove-crypto::invite`. The DB ops (`create_invite_record`,
  `lookup_invite`, `mark_consumed`), the REST handler (`preview_invite`),
  and the `InviteState`/`InviteRow` types remain in `server/src/invites.rs`.
- `wordlist_bip39_en.rs` → `littlelove-crypto::wordlist`.
- A new `littlelove-crypto::aead` module exposing the XChaCha20-Poly1305
  wire envelope (encrypt → wire string, decrypt ← wire string) that
  byte-matches `app/lib/crypto/cipher.dart`.
- A new `littlelove-crypto::ecdh` module: X25519 ECDH + HKDF-SHA256 with
  the spec §5.1 salt/info layout, producing the 32-byte room key.
- A new `littlelove-crypto::identity` module: BIP39 phrase → seed,
  HKDF-derived Ed25519 + X25519 keypairs per spec §3.1.

`server/` adds `littlelove-crypto` as a workspace dep and re-exports what
its callers need. `bot/` adds it too. Zero behaviour change for the server
(tests prove this).

**Rejected alternative:** duplicate the primitives in `bot/`. Faster to
write, easier to ship in isolation, structurally unsafe.

**Status:** Recommendation. **Court must confirm before WT-bot starts
touching files in `server/`.** If Court prefers the duplicated path, the
spec is amended and the WT continues on a duplicate-and-fuzz-test basis.

### 3.2 New workspace layout

```
Cargo.toml                  # workspace root, members += ["crypto", "bot"]
crypto/                     # NEW: littlelove-crypto
  src/
    lib.rs
    sig.rs                  # from server/src/auth.rs (verify/sign + domain tags)
    invite.rs               # BIP39 encode/decode/canonical token/sha256/generate
    wordlist.rs             # the 2048-word BIP39 table
    aead.rs                 # XChaCha20-Poly1305 + wire-envelope packing
    ecdh.rs                 # X25519 + HKDF → room key
    identity.rs             # phrase → seed → keypairs
  tests/
    invite_vectors.rs       # asserts against server/tests/data/invite_vectors.json
    domain_separation.rs    # signing-input layouts (mirrors server tests)
    aead_roundtrip.rs       # encrypt/decrypt parity + a Dart-shaped fixture
server/                     # existing crate, refactored to depend on `littlelove-crypto`
bot/                        # NEW: littlelove-bot (binary)
  Cargo.toml
  src/
    main.rs                 # clap subcommands: pair, run, show-identity
    cli.rs
    config.rs               # CLI + env + paths
    identity_store.rs       # ~/.littlelove-bot/identity.json (+ macOS Keychain wrap)
    rest.rs                 # POST /accounts, POST /invites/{code}/preview
    ws_client.rs            # WSS Challenge → Identify → Authenticated, frame I/O
    pair.rs                 # one-shot pair flow
    room.rs                 # subscribe + encrypt/decrypt + dispatch
    llm.rs                  # OpenAI-compatible chat-completions client
    history.rs              # bounded in-memory conversation buffer
    addr_guard.rs           # private-IP check for the LLM endpoint
    persona.rs              # resolves: --character-card | --system-prompt-file | env | default
    character_card.rs       # CCv2/v3 PNG → card struct → flattened system prompt
  tests/                    # crate-level integration tests (no DB)
```

### 3.3 Workspace `Cargo.toml` additions

```toml
[workspace]
members = ["crypto", "server", "bot"]

[workspace.dependencies]
# additions (existing entries unchanged)
clap          = { version = "4", features = ["derive", "env"] }
directories   = "5"      # XDG paths / macOS Application Support
ed25519-dalek = "2"
x25519-dalek  = { version = "2", features = ["static_secrets"] }
hkdf          = "0.12"
sha2          = "0.10"
chacha20poly1305 = "0.10"  # XChaCha20-Poly1305 (XChaCha20Poly1305 type)
rand          = "0.8"
reqwest       = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
hex           = "0.4"
png           = "0.17"     # CCv2 PNG chunk extraction (tEXt/iTXt)
# base64, serde, serde_json, tokio, tokio-tungstenite, tracing already exist
```

The bot crate uses `reqwest` with `rustls` (no openssl) so cross-compiling
to Windows is straightforward and no extra system libs land on Court's
machine.

---

## 4. Bot Identity Persistence

The bot owns a single LittleLove identity that needs to survive restarts.

### 4.1 What we persist

A JSON file at `$XDG_CONFIG_HOME/littlelove-bot/identity.json` (Linux),
`~/Library/Application Support/littlelove-bot/identity.json` (macOS), or
`%APPDATA%\littlelove-bot\identity.json` (Windows). Resolved via the
`directories` crate.

Schema:
```json
{
  "version": 1,
  "username": "court-familiar",
  "ed25519_pub_b64": "...",
  "x25519_pub_b64": "...",
  "master_secret_b64": "<32-byte HKDF master, base64>",
  "created_at": "2026-06-09T..."
}
```

We do **not** persist the BIP39 recovery phrase — the master secret is
sufficient to re-derive both keypairs. We do not persist the keypairs in
cleartext (they're recomputed from the master at every launch).

### 4.2 At-rest protection

**v0.2-bot threat model:** Court is the only human who runs this. The
identity file shares a directory with the LLM model weights, the system
prompt, and Court's whole home directory. If an attacker has filesystem
access, the bot identity is already not the most interesting thing they
can take.

Given that: write the file mode `0600` on Unix; on Windows rely on the
default user-profile DACL. **No OS keystore integration in WT-bot.**
Wrapping a 32-byte secret in macOS Keychain via `security-framework`
roughly doubles the platform-specific code (and the test surface) for a
threat model that the rest of the file already loses to. Phase 1 can
revisit if the bot ships to more than one user.

The Flutter app's choice of `flutter_secure_storage` is unchanged — that
identity belongs to the human, sees biometric unlock, and lives behind
Touch ID / Windows Hello. The bot identity has neither protection nor
need of it.

### 4.3 First-run vs subsequent runs

- `bot pair --code <four-words> [--username <u>]` requires that the file
  does NOT exist (or `--force` is passed, which deletes it). It generates
  the master, signs up via `POST /accounts`, completes the WSS handshake,
  signs the invite token, and only writes `identity.json` on success.
- `bot run` requires that the file exists. It loads the master, re-derives
  the keypairs, connects, and listens.
- `bot show-identity` prints the username and public-key fingerprints for
  Court to sanity-check.

---

## 5. Trigger Model

Default: respond to **every inbound `Message` frame** where `from !=
self.username` and `replayed == false`. The room is 1:1 by spec and the
bot is the only non-Court participant in it; there are no false-positive
participants to disambiguate.

Replayed messages (server-side history pushed after `Subscribe`) are
ignored for triggering but ARE folded into the conversation history (§7)
so a fresh bot launch has context.

No configurable trigger modes in v0.2-bot. (`@bot` / `/ai` mentions are a
Phase-1 concern once familiars share a room with two humans.)

Echo-storm protection: the bot never replies to a message whose `from`
equals its own username. Decryption failures are logged and silently
dropped — never sent back as a message — to avoid a corrupted-message
storm.

---

## 6. LLM Transport

### 6.1 Endpoint

- Default URL: `http://localhost:8080/v1` (llama.cpp's `llama-server`).
- Override via `--llm-url <url>` or `LITTLELOVE_BOT_LLM_URL` env.
- Override the model name (sent in the request body) via `--model
  <name>` or env. Default: `local-model` — `llama-server` accepts any
  string in the `model` field; downstream OpenAI-compatible servers
  (Ollama, vLLM, LM Studio) all do too.

### 6.2 Private-IP guard (§10 enforcement)

`addr_guard.rs` resolves the URL's host to an `IpAddr` and refuses to
proceed unless it is one of:

- IPv4 loopback `127.0.0.0/8`
- IPv4 private `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- IPv4 link-local `169.254.0.0/16`
- IPv6 loopback `::1`
- IPv6 unique-local `fc00::/7`
- IPv6 link-local `fe80::/10`

Hostnames are resolved at bot startup and re-resolved before each request
(cheap; DNS caches it). A name that resolves to a public IP causes the bot
to log a refusal and exit (during `pair`) or skip the reply (during `run`).
This is structural per the positioning doc: there is no flag, env var, or
config option that bypasses it.

### 6.3 Request shape

`POST {llm_url}/chat/completions`, OpenAI-compatible:
```json
{
  "model": "local-model",
  "messages": [
    { "role": "system", "content": "<system prompt>" },
    { "role": "user", "content": "<oldest history>" },
    ...
    { "role": "user", "content": "<just-arrived message>" }
  ],
  "stream": false,
  "temperature": 0.8,
  "max_tokens": 512
}
```

`temperature` and `max_tokens` are CLI flags with the defaults above.

### 6.4 Timeouts and retry

- 60-second request timeout. Long enough for a 7B Q4 to chew through a
  500-token reply on CPU; short enough that a hung endpoint doesn't wedge
  the bot forever.
- No retry. A single failure → the bot sends an `[llm error: <short
  reason>]` message back to the room as a regular encrypted body. Silent
  drop is worse: Court would see his message land and then wonder if the
  bot is alive. A visible error reply keeps the inbox honest.

### 6.5 Concurrency

The bot processes one inbound message at a time. If a second message
arrives while the first is mid-call to the LLM, it queues (Tokio
`mpsc::unbounded`). This avoids interleaved replies that would confuse the
conversation history and keeps Court's mental model simple: one in, one
out, in order.

---

## 7. Conversation Memory

In-memory bounded ring buffer. Default capacity 20 messages (10 turns).
Configurable via `--history <N>` / `LITTLELOVE_BOT_HISTORY`.

On `Subscribe` reply, the server's replayed messages backfill the buffer
in order. Live messages (both from Court and the bot's own outgoing
replies) push to the buffer. On overflow, the oldest entry drops.

**No persistence.** Restart drops history. Acceptable for v0.2-bot because:
- The server still has the encrypted history; `Subscribe` replays it.
- A persistent on-disk history would be a second copy of plaintext to
  protect, and the threat model already loses to local-filesystem access.

History format passed to the LLM: each room message becomes an OpenAI
chat message with `role = "user"` if from Court, `role = "assistant"` if
from the bot itself. We use the `from` field on `Message` frames to
distinguish; the server forces `from` to the authenticated username so
this is trustworthy.

---

## 8. Persona — Character Cards + Plain System Prompts

The bot's persona is shaped by exactly one of these sources, picked at
startup and held for the lifetime of the process. The sources are
**mutually exclusive**: setting more than one is a configuration error
and the bot exits non-zero with a clear message. This is clearer than a
precedence rule when the operator inevitably forgets which one is set.

### 8.1 Persona sources (mutually exclusive)

1. `--character-card <path.png>` — Character Card v2/v3 PNG. See §8.3.
2. `--system-prompt-file <path>` — plain UTF-8 text file. File contents
   used verbatim as the system prompt.
3. `LITTLELOVE_BOT_SYSTEM_PROMPT` env var — literal prompt string, not a
   path. Convenient for `systemd`-style deployments.
4. None of the above → the default below (§8.2).

If two or more of (1), (2), (3) are set simultaneously, the bot prints
`error: pass only one of --character-card, --system-prompt-file, or
LITTLELOVE_BOT_SYSTEM_PROMPT` to stderr and exits with status 2.

### 8.2 Default system prompt (if no source is given)

> You are an AI familiar running locally on your operator's hardware. You
> live in a private end-to-end encrypted chat with one person — the person
> talking to you right now. You are not a person and you do not pretend to
> be one. You are sober, plainspoken, and brief by default. You do not
> volunteer opinions on the operator's partner, family, or relationships
> unless asked. You do not moralize. If the operator wants longer or
> warmer responses, they will ask, and you will oblige.

**Status:** Recommendation. Court approves or rewrites before merge —
this prompt represents him to himself.

### 8.3 Character Card v2 / v3 PNG handling

**Loader.**
1. Open the PNG with the `png` crate; iterate over tEXt and iTXt chunks.
2. Look for a chunk whose keyword is `ccv3` first, then `chara` (V2
   fallback). The chunk value is base64-encoded JSON.
3. Base64-decode → `serde_json::from_slice` into a struct mirroring the
   CCv2 shape:

   ```rust
   struct CharacterCardEnvelope { spec: String, data: CharacterCardData }
   struct CharacterCardData {
     name: String,                    // used + required (for {{char}})
     description: String,             // optional, used in template
     personality: String,             // optional, used in template
     scenario: String,                // optional, used in template
     system_prompt: String,           // optional, overrides template
     creator: Option<String>,         // logged, not used in prompt
     character_version: Option<String>,
     // every other CCv2 field is parsed-but-ignored
   }
   ```
4. Unknown fields are ignored (`#[serde(deny_unknown_fields)] is NOT
   used`) so cards from the wild don't crash the loader.

**Field selection.** v0.2-bot uses exactly:
- `name` — for `{{char}}` substitution.
- `system_prompt` — used verbatim when non-empty (highest priority).
- `description`, `personality`, `scenario` — combined via §8.4 template
  when `system_prompt` is empty.
- `creator`, `character_version` — logged at startup, not sent to LLM.

**Fields explicitly dropped in v0.2-bot** (parsed and ignored; documented
so users understand the limitation):
- `first_mes` — would require a "send first message on pair" hook; out.
- `mes_example` — few-shot examples need careful wiring into history; out.
- `alternate_greetings` — no UI to choose; out.
- `character_book` (lorebook) — full retrieval system; out.
- `post_history_instructions` — would require injecting between history
  and the latest user message; out.

A follow-up WT picks these up if Court wants them.

### 8.4 Default template (when `system_prompt` is empty)

```
{{char}}'s Persona: {description}

Personality: {personality}

Scenario: {scenario}

[Start a new chat between {{user}} and {{char}}]
```

- Any section whose source field is empty after trimming is dropped
  entirely (no blank "Personality:" header dangling).
- After the template is assembled, `{{char}}` is substituted with `name`
  and `{{user}}` with the bot operator's `username` (from
  `identity.json`). The double-brace placeholders are the SillyTavern
  convention; community cards rely on them.
- The same `{{char}}`/`{{user}}` substitution is applied even when a
  card's `system_prompt` is used verbatim, since cards in the wild
  commonly put `{{char}}` inside their own `system_prompt`.

### 8.5 Startup logging

On a successful card load, the bot logs (at `INFO`):

```
loaded character card: "Aria" (V2, by @somecreator, version 1.3)
```

Missing fields show as `unknown` (e.g. `by unknown`). This is a sanity
check, not a security boundary — Court sees what loaded before any
encrypted message goes out.

### 8.6 Error cases

- PNG has no `ccv3`/`chara` chunk → exit 2 with `error: <path>: not a
  Character Card PNG (no ccv3 or chara chunk found)`.
- Chunk present but not valid base64 → exit 2 with the underlying error.
- Decoded JSON missing `data.name` → exit 2.
- File doesn't exist / not a PNG → exit 2 with the IO/decode error.

---

## 9. Pairing UX

### 9.1 First-time flow (one-time per machine)

1. Court opens the Flutter desktop app, signed in as `court`.
2. Court taps "Pair with partner" → gets a four-word code, e.g.
   `amber-fern-locket-tide`.
3. In a terminal on the same machine, Court runs:
   ```
   littlelove-bot pair \
     --server wss://littlelove.example.org \
     --code amber-fern-locket-tide \
     --username court-familiar
   ```
4. The bot:
   - Validates the LLM URL resolves to a private IP. (Logged "LLM endpoint
     OK: 127.0.0.1".)
   - Generates a fresh 32-byte master secret via `OsRng`.
   - Derives Ed25519 + X25519 keypairs per spec §3.1.
   - `POST /accounts {username, ed25519_pub, x25519_pub}` (signup).
   - Opens WSS, performs the Challenge/Identify/Authenticated handshake.
   - Sends `ConsumeInvite { code, signature_over_token }` using the
     domain-separated invite-consume signing input.
   - On `InviteConsumed { room_id, peer_username, peer_ed25519_pub,
     peer_x25519_pub }`:
     - Writes `identity.json` (atomic rename, mode 0600).
     - Caches the room descriptor in memory.
     - Prints "Paired with @court. Identity saved."
     - Exits.

### 9.2 Subsequent flow

`littlelove-bot run --server wss://... [--llm-url http://...]`

The bot reads `identity.json`, reconnects, the server sends `Rooms`
(non-empty because the room exists), and the bot extracts the same peer
descriptor that `pair` cached. From there it `Subscribe`s and listens.

### 9.3 Recovery / re-pair

There is no recovery path. The bot is its own identity; losing
`identity.json` means losing the bot's place in the room. Court would
have to:
1. From the human Flutter app, leave the room (out of scope — Phase 1).
2. Re-create a fresh invite.
3. Re-run `bot pair`.

The bot prints a banner when starting paired that names this risk. v0.2
does not implement room-leave, so a lost `identity.json` is unrecoverable
without server-side intervention. Court owns the server. Acceptable.

---

## 10. Cloud-LLM Refusal (Positioning Contract)

This is non-negotiable per `docs/positioning.md`:

> No cloud AI providers — ever. We do not integrate with OpenAI, Anthropic,
> OpenRouter, or any cloud LLM. Not as a default. Not as an option you can
> enable. This is structural, not policy: if there is no code path that
> sends your messages to a third-party LLM, there is no way for those
> companies to train on your conversations.

Implementation:

1. The OpenAI-compatible HTTP client speaks one shape (chat-completions).
   There is no `provider` enum to switch on, no Anthropic shape parallel.
2. `addr_guard.rs` rejects any URL whose host does not resolve to a
   private IP (§6.2). There is no env var, CLI flag, or build feature
   that bypasses it. The test suite includes a "tries to connect to
   1.1.1.1, gets refused" assertion.
3. The default URL is `http://localhost:8080/v1`. The default leans
   correct.
4. No reference to `api.openai.com`, `api.anthropic.com`, or any other
   cloud LLM host exists anywhere in the bot crate — including comments,
   examples, or test fixtures.

---

## 11. Wire Compatibility

The bot speaks v0.2 §8.2 frames exactly:

- WSS Challenge → Identify → Authenticated → Rooms → Subscribe →
  Message[replayed=true]* → live Message frames.
- Outbound: `Send { room_id, body: <wire body>, client_msg_id: <uuid> }`.

The `body` wire format matches `app/lib/crypto/cipher.dart`:
1. XChaCha20-Poly1305 encrypt: plaintext UTF-8 → ciphertext (length =
   plaintext.len + 16 byte MAC appended).
2. JSON `{ "ciphertext": base64(ciphertext||mac), "nonce":
   base64(nonce) }`.
3. UTF-8 encode that JSON, then base64 again. That outer base64 string
   IS the wire `body` field.

This double-base64 envelope is what the Dart client built; the bot
follows it byte-for-byte so the Flutter app on Court's Mac and the bot on
the same Mac both decrypt each other's messages cleanly.

The crypto crate exposes `aead::encrypt_wire(key, plaintext) -> String`
and `aead::decrypt_wire(key, wire) -> String` so the bot doesn't
reimplement the envelope.

---

## 12. CI

A new bot crate joins the workspace, so:

- `cargo fmt --check` on the workspace already covers it.
- `cargo clippy --workspace -- -D warnings` already covers it.
- `cargo test --workspace` already covers it.
- The existing `Rust API` required check in CI (build + lint + tests for
  the server crate) becomes `Rust workspace` — both server and bot run
  through the same matrix on every PR.
- A new GitHub Actions job in `release.yml` cross-builds
  `littlelove-bot` for `macos-latest` (x86_64 + aarch64),
  `windows-latest` (x86_64), and `ubuntu-latest` (x86_64) on every `v*`
  tag and attaches the resulting binaries to the release. Per Court's
  standing split-release/deploy preference: this lives in `release.yml`,
  not in `deploy.yml`. The bot is user-installed; nothing to deploy.

The crypto crate likewise rides the workspace `fmt/clippy/test` matrix.

---

## 13. Test Strategy

TDD-first per Court's preference. Each task in §14 of the implementation
plan starts with a failing test.

### 13.1 crypto crate tests
- `sig`: domain-separation layouts (mirrors server tests), strict
  verify_strict, cross-context refusal.
- `invite`: round-trip encode/decode, `server/tests/data/invite_vectors.json`
  parity (loaded from the file — single source of truth).
- `ecdh`: X25519 shared-secret commutativity, HKDF salt/info bytes match
  spec §5.1.
- `identity`: BIP39 phrase → master → keypair derivation; same phrase →
  same pubkeys.
- `aead`: encrypt → wire string → decrypt round-trip. A "decrypt a
  Dart-emitted envelope" fixture (a small embedded JSON blob captured
  from the cipher.dart tests) confirms cross-language parity.

### 13.2 bot crate tests
- `addr_guard`: positive cases (localhost, 10.x, 192.168.x, ::1, fe80::)
  and a curated table of public IPs (1.1.1.1, 8.8.8.8, 2606:4700::1).
  Hostname resolution mocked via a small trait.
- `identity_store`: write → read round-trip; mode 0600 on Unix; refuses
  to overwrite without `--force`.
- `history`: ring-buffer eviction, role-mapping (`from == self ⇒
  assistant`).
- `llm`: a Tokio test that spins up a tiny `axum` mock server speaking
  OpenAI chat-completions; bot sends, parses reply, encrypts, would have
  sent (uses a fake ws sink).
- `character_card`: parse a V2 fixture PNG, parse a V3 fixture PNG,
  `{{char}}`/`{{user}}` substitution, `system_prompt`-present uses
  verbatim, `system_prompt`-empty assembles the §8.4 template, empty
  optional sections are dropped, malformed PNG exits non-zero with a
  clear message.
- `persona`: mutual-exclusion of `--character-card`,
  `--system-prompt-file`, and the env var (setting any two exits 2);
  default-baked prompt is selected when none is set.
- `ws_client`: handshake against an embedded server-side simulator that
  reuses `littlelove-crypto::sig::verify_signature`. Doesn't need a real
  Postgres.
- An end-to-end test (gated `#[ignore]` by default) that:
  1. Spins up the real `server` binary against an ephemeral Postgres.
  2. Creates an inviter account programmatically.
  3. Mints an invite via the WS API.
  4. Runs `bot pair` in-process against it.
  5. Sends a message from the inviter, asserts the bot's reply lands
     decryptable.

  The `#[ignore]` keeps it out of the fast CI lane but Court can run it
  locally with `cargo test -p littlelove-bot -- --ignored`.

### 13.3 Refactor parity (`server/` move)
- The existing server tests stay green after the crypto extraction. Any
  test that breaks means the move changed behavior — that's a bug, not a
  test update.

---

## 14. Acceptance Criteria

The PR may not be merged until:

1. `cargo fmt --check`, `cargo clippy --workspace -- -D warnings`,
   `cargo test --workspace` all clean on macOS and Linux runners.
2. `flutter test` from `app/` passes unchanged.
3. The crypto crate exists; the server's existing crypto unit tests
   pass against it; no protocol byte layout has changed.
4. Court runs the manual smoke (separate from CI):
   1. Starts `llama-server` with a small model on `127.0.0.1:8080`.
   2. Creates an invite from the Flutter app.
   3. `littlelove-bot pair --code <...>` succeeds, prints "Paired with
      @court."
   4. `littlelove-bot run` connects and idles.
   5. Court sends "hello" from the Flutter app; the bot's reply arrives
      in the inbox within ~20 seconds (depends on model size).
   6. Bot is restarted; sends another message; conversation continues
      with the recent history visible to the LLM (verify via bot logs
      showing the history payload it built).
5. The cross-platform release builds attach to the next `v0.2.x` tag
   without manual intervention.
6. The bot accepts a community-shaped Character Card v2 PNG via
   `--character-card` and uses its persona for replies. A V3 PNG also
   loads. The startup log line names the character.

---

## 15. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Crypto crate extraction breaks the server's protocol in a subtle way | Spec §13.3: existing server tests stay green; if any moves, that's a regression. Plus, the `crypto/tests/invite_vectors.rs` test loads the same `server/tests/data/invite_vectors.json` fixture WT-B already wrote — divergence is structurally impossible. |
| Bot's double-base64 envelope drifts from `cipher.dart` | Embedded fixture: a base64 envelope captured from a Dart test goes into `crypto/tests/aead_roundtrip.rs` and must decrypt with a known key. |
| LLM hangs or rate-limits, bot wedges | 60-second timeout; visible `[llm error: ...]` reply; queue is bounded (drops oldest if it grows past 64 entries). |
| Operator misconfigures `--llm-url` to a public IP and silently loses privacy | `addr_guard` refuses; on `pair` the bot exits non-zero; on `run` the bot logs and skips replies. Operator sees the error. |
| `identity.json` is exfiltrated | Documented: equivalent to losing the bot's account. The human account (Court's own) is unaffected because it's a separate identity with its own keypair behind the Flutter keystore. |
| Bot replies to its own messages, infinite loop | Skip-self check on `from`. Test covers it. |
| Character Card with weaponized JSON (huge fields, deeply nested) crashes the bot | `png` crate has a built-in chunk-size cap; we additionally cap card JSON at 1 MiB before base64-decode; flattened prompt string is capped at 64 KiB. |
| Unsupported CCv2 fields (`character_book`, `mes_example`) silently make the card behave differently than its author intended | Documented in §8.3; startup log emits `note: dropped fields: <list>` when present so the operator sees what was ignored. |

---

## 16. Open Questions (must be closed before plan)

Closed inline by Court during brainstorming:
- **Character Card v2/v3 PNG support — IN scope for this WT.** Bundles
  with v0.2-bot rather than landing as a follow-up WT. See §8.3–§8.6.

Still open (Court answers in one pass):

1. **Shared `littlelove-crypto` crate? (§3.1)** — recommendation: yes.
   Refusing means the bot duplicates ~600 LoC of crypto and ships with a
   property-test parity harness instead of structural sharing.
2. **Default system-prompt voice (§8.2).** — recommendation: the sober,
   plainspoken default above. Court approves or replaces. Note: with
   character cards in scope, the default only fires when no card and no
   `--system-prompt-file` and no env var are set — so this default is
   mostly the "developer with no card handy" path.
3. **Bot username (§9.1).** — recommendation: leave it as a `--username`
   flag, no default, so Court chooses something he'll recognize in the
   sidebar (e.g. `familiar`, `assistant`, his own preference). Server
   §3.1 only requires `[a-z0-9_]{3,20}`.

Everything else is fixed by the brief + the v0.2 spec.

---

## 17. References

- `docs/positioning.md` §"Bring your own AI" + the table row defending "we reject cloud AI providers."
- `docs/superpowers/specs/2026-06-09-littlelove-accounts-and-inbox-design.md` §3 (identity), §4 (pairing), §5 (per-room encryption), §8.2 (WS frames), §8.5–8.5.1 (domain separation), §8.6 (BIP39 invites).
- `server/src/auth.rs`, `server/src/invites.rs`, `server/src/rooms.rs`, `server/src/ws.rs` — the SERVER side of the same protocol.
- `server/tests/data/invite_vectors.json` — ground-truth fixture for BIP39 invite encoding.
- `app/lib/crypto/cipher.dart` — the wire-body envelope format the bot must match.
- RFC 8032 (Ed25519), RFC 7748 (X25519), RFC 5869 (HKDF), RFC 7539 (ChaCha20-Poly1305), BIP39.
- Character Card V2 spec: https://github.com/malfoyslastname/character-card-spec-v2 — defines the `chara`/`ccv3` tEXt chunk format and field semantics this bot implements a subset of.
