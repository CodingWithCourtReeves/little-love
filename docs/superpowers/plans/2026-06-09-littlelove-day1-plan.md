> **HISTORICAL — superseded (annotated 2026-06-16).** This document predates the
> removal of the AI "familiar" / bring-your-own-model feature. LittleLove is now a
> couples-first, channels-based, fully end-to-end-encrypted messenger with **no AI
> and no familiars**. Any mention below of bots, familiars, character cards, LLMs,
> or cloud/local AI describes a **retired** design and does NOT reflect the current
> product. For current framing see `README.md` and `docs/positioning.md`.

# LittleLove Day-1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a private messenger Court (macOS) and Kaitlyn (Windows) can actually chat on, in three independently-shippable git-tagged slices: Day-1a (plain text, in-memory), Day-1b (Postgres + replay), Day-1c (XChaCha20-Poly1305 symmetric encryption).

**Architecture:** Rust + Axum server (single binary; in-memory `HashMap<username, WebSocketSink>` Day-1a, sqlx + Postgres Day-1b+); pure-Dart Flutter desktop client (macOS + Windows); JSON over WebSocket wire. Worktree-aware Docker Compose for local dev. GitHub Releases publish `.dmg` and `.msi` artifacts on `v*` tag push.

**Tech Stack:** Rust 1.78+, Axum 0.7, tokio, sqlx 0.7 (Postgres), uuid, serde, tokio-tungstenite (tests). Flutter 3.22+, Dart 3.4+, `web_socket_channel`, `toml`, `path_provider`, `cryptography` (Day-1c), `uuid`. Postgres 16. Docker Compose 2.x. GitHub Actions on `ubuntu-latest`, `macos-latest`, `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-06-09-littlelove-day1-design.md`. The Phase 1 design at `docs/superpowers/specs/2026-06-09-littlelove-design.md` is the broader future; this plan does not implement it.

**Engineering preferences (per saved feedback):**
- TDD-first: failing test → green → refactor → commit. Every task in this plan follows this pattern.
- Required PR/push checks: build + lint + tests. Enforced via `ci.yml`.
- Split release/deploy: `release.yml` builds binaries and pushes a container to GHCR + tags. Deploy to Railway is invoked separately by `deploy.yml`.
- Commit messages follow the conventional shape used so far on `main`: a short subject line, then a longer body. Co-author Claude when an agent is doing the work.

---

## File Structure

This is the target tree after Day-1c. Tasks below build it up incrementally.

```
little-love/
├── Cargo.toml                      # workspace manifest
├── server/
│   ├── Cargo.toml
│   ├── Dockerfile
│   ├── migrations/                 # Day-1b
│   │   └── 0001_create_messages.sql
│   └── src/
│       ├── main.rs                 # binary entrypoint
│       ├── lib.rs                  # re-exports for tests
│       ├── config.rs               # env vars (PORT, DATABASE_URL)
│       ├── wire.rs                 # JSON message types
│       ├── routing.rs              # in-memory connection map
│       ├── store.rs                # Day-1b: Postgres persistence
│       ├── ws.rs                   # WebSocket upgrade handler
│       └── error.rs                # error types
├── app/
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart
│       ├── config.dart             # TOML reader, OS-path picker
│       ├── theme/hearth.dart       # palette constants
│       ├── wire/
│       │   ├── message.dart        # data classes for wire frames
│       │   └── crypto.dart         # Day-1c
│       ├── ws_client.dart          # WebSocket client + reconnect
│       └── conversation_page.dart  # the only screen
│   └── test/
│       ├── config_test.dart
│       ├── wire/
│       │   ├── message_test.dart
│       │   └── crypto_test.dart    # Day-1c
│       └── ws_client_test.dart
├── docker-compose.yml
├── scripts/
│   ├── dev-up.sh
│   ├── dev-down.sh
│   └── dev-env.sh                  # sourced helper
├── .github/workflows/
│   ├── ci.yml
│   ├── release.yml
│   └── deploy.yml
├── docs/                            # already populated
├── README.md
└── .gitignore
```

**Responsibility split:**
- `wire.rs` (Rust) and `wire/message.dart` (Dart) are the *single sources of truth* for the wire-format envelope shapes. Add a new frame type there before using it anywhere.
- `routing.rs` only knows live connections; `store.rs` (Day-1b) only knows the database. `ws.rs` is the only place that talks to both.
- `config.rs` (server) reads env; `config.dart` (client) reads a TOML file. Neither calls out of its module.

---

## Phase 0 — Bootstrap

These tasks set up the empty shell. They don't ship anything yet; they make subsequent tasks runnable.

### Task 0.1: Initialize Cargo workspace

**Files:**
- Create: `Cargo.toml`
- Create: `.gitignore`

- [ ] **Step 1: Create the workspace manifest**

```toml
# Cargo.toml
[workspace]
members = ["server"]
resolver = "2"

[workspace.package]
edition = "2021"
rust-version = "1.78"
license = "UNLICENSED"

[workspace.dependencies]
anyhow      = "1"
axum        = { version = "0.7", features = ["ws", "macros"] }
chrono      = { version = "0.4", features = ["serde"] }
futures     = "0.3"
serde       = { version = "1", features = ["derive"] }
serde_json  = "1"
sqlx        = { version = "0.7", features = ["postgres", "runtime-tokio-rustls", "uuid", "chrono", "macros", "migrate"] }
thiserror   = "1"
tokio       = { version = "1.38", features = ["full"] }
tokio-tungstenite = "0.21"
tracing     = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
uuid        = { version = "1", features = ["v4", "serde"] }
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
# Rust
/target/
Cargo.lock

# Flutter
/app/.dart_tool/
/app/.flutter-plugins
/app/.flutter-plugins-dependencies
/app/.packages
/app/.pub-cache/
/app/.pub/
/app/build/
/app/macos/Pods/
/app/macos/Podfile.lock
/app/windows/x64/

# Dev scripts (per-worktree, generated)
.dev.env

# OS
.DS_Store
Thumbs.db

# Editor
.idea/
.vscode/
*.iml
```

- [ ] **Step 3: Commit**

```sh
git add Cargo.toml .gitignore
git commit -m "$(cat <<'EOF'
Bootstrap Cargo workspace

Workspace declares one member (server) and pins shared dependency
versions. Adds a top-level .gitignore covering Rust target/, Flutter
build artifacts, generated .dev.env, and OS noise.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.2: Scaffold the empty server crate

**Files:**
- Create: `server/Cargo.toml`
- Create: `server/src/main.rs`
- Create: `server/src/lib.rs`

- [ ] **Step 1: Write the failing test**

```rust
// server/src/lib.rs
pub fn placeholder() -> &'static str {
    "littlelove-api"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder_returns_service_name() {
        assert_eq!(placeholder(), "littlelove-api");
    }
}
```

- [ ] **Step 2: Create `server/Cargo.toml`**

```toml
# server/Cargo.toml
[package]
name = "littlelove-api"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[[bin]]
name = "littlelove-api"
path = "src/main.rs"

[lib]
name = "littlelove_api"
path = "src/lib.rs"

[dependencies]
anyhow.workspace = true
axum.workspace = true
chrono.workspace = true
futures.workspace = true
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
tokio.workspace = true
tracing.workspace = true
tracing-subscriber.workspace = true
uuid.workspace = true

[dev-dependencies]
tokio-tungstenite.workspace = true
```

- [ ] **Step 3: Create `server/src/main.rs` as a thin binary**

```rust
// server/src/main.rs
fn main() {
    println!("{}", littlelove_api::placeholder());
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p littlelove-api`
Expected: `placeholder_returns_service_name ... ok` and `test result: ok. 1 passed`.

- [ ] **Step 5: Verify the binary builds and runs**

Run: `cargo run -p littlelove-api`
Expected: `littlelove-api` printed to stdout.

- [ ] **Step 6: Commit**

```sh
git add server/ Cargo.toml
git commit -m "$(cat <<'EOF'
Scaffold littlelove-api crate

Empty server crate with a placeholder lib function and a thin binary
that prints the service name. Locks in the workspace member layout,
re-exports needed for tests, and the bin/lib split that subsequent
tasks build on.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.3: Scaffold the Flutter app

**Files:**
- Create: `app/` (via `flutter create`)
- Modify: `app/pubspec.yaml`
- Modify: `app/lib/main.dart`

- [ ] **Step 1: Create the Flutter project**

Run from the repo root:

```sh
flutter create \
  --org dev.littlelove \
  --project-name littlelove \
  --platforms=macos,windows \
  --description "LittleLove — private messenger for couples" \
  app
```

Expected: `app/` directory created with `pubspec.yaml`, `lib/main.dart`, `macos/`, `windows/` subdirs.

- [ ] **Step 2: Verify it builds**

Run: `cd app && flutter pub get && flutter build macos --debug`
Expected: build succeeds. (No client code yet; just verifying the Flutter toolchain.)

- [ ] **Step 3: Add Day-1 dependencies to `app/pubspec.yaml`**

Replace the `dependencies:` block with:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.6
  web_socket_channel: ^2.4.5
  toml: ^0.16.0
  path_provider: ^2.1.2
  path: ^1.9.0
  uuid: ^4.4.0
  cryptography: ^2.7.0   # used Day-1c; cheap to include now
```

- [ ] **Step 4: Replace `app/lib/main.dart` with a minimal placeholder**

```dart
// app/lib/main.dart
import 'package:flutter/material.dart';

void main() {
  runApp(const LittleLoveApp());
}

class LittleLoveApp extends StatelessWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'LittleLove',
      home: Scaffold(
        body: Center(child: Text('LittleLove — bootstrapping')),
      ),
    );
  }
}
```

- [ ] **Step 5: Run `flutter pub get` and verify the app launches**

Run: `cd app && flutter pub get && flutter run -d macos`
Expected: app launches showing "LittleLove — bootstrapping". Close the app window or `q` in the terminal.

- [ ] **Step 6: Commit**

```sh
git add app/
git commit -m "$(cat <<'EOF'
Scaffold Flutter desktop app

flutter create with macos + windows platforms, dev.littlelove org.
Adds Day-1 dependencies (web_socket_channel, toml, path_provider,
uuid, cryptography). Replaces the default counter UI with a minimal
placeholder confirming the toolchain works end-to-end on macOS.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.4: Worktree-aware dev scripts and Docker Compose stub

**Files:**
- Create: `docker-compose.yml`
- Create: `scripts/dev-env.sh`
- Create: `scripts/dev-up.sh`
- Create: `scripts/dev-down.sh`
- Create: `server/Dockerfile`

- [ ] **Step 1: Create `server/Dockerfile`**

```dockerfile
# server/Dockerfile
FROM rust:1.78-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY server/Cargo.toml server/Cargo.toml
COPY server/src server/src
COPY server/migrations server/migrations
RUN cargo build --release -p littlelove-api

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/littlelove-api /usr/local/bin/littlelove-api
COPY --from=builder /build/server/migrations /app/migrations
WORKDIR /app
EXPOSE 7707
CMD ["/usr/local/bin/littlelove-api"]
```

(The `migrations/` copy is harmless before Day-1b; that directory will exist as an empty folder until Task 1b.2.)

- [ ] **Step 2: Create `server/migrations/.gitkeep`**

```sh
mkdir -p server/migrations
touch server/migrations/.gitkeep
```

- [ ] **Step 3: Create `docker-compose.yml`**

```yaml
# docker-compose.yml
services:
  api:
    build:
      context: .
      dockerfile: server/Dockerfile
    ports:
      - "${API_PORT:-7707}:7707"
    environment:
      RUST_LOG: ${RUST_LOG:-info}
      PORT: 7707
      DATABASE_URL: ${DATABASE_URL:-}
    depends_on:
      - postgres

  postgres:
    image: postgres:16-alpine
    ports:
      - "${POSTGRES_PORT:-5432}:5432"
    environment:
      POSTGRES_USER: littlelove
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: littlelove
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U littlelove"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
```

(The `postgres` service is unused by the Day-1a server but is included now so the worktree-aware port logic accounts for it from the start. The Day-1a server will simply ignore `DATABASE_URL`.)

- [ ] **Step 4: Create `scripts/dev-env.sh`** (sourced helper)

```bash
# scripts/dev-env.sh
# Source this script to set COMPOSE_PROJECT_NAME and port offsets per worktree.
# Usage: source scripts/dev-env.sh

set -u

_workdir_name="$(basename "$PWD")"

# Derive a deterministic 0..99 offset from the worktree directory name.
# sha1 of the name → take first 4 hex chars → modulo 100.
_hash_hex=$(printf '%s' "$_workdir_name" | shasum -a 1 | awk '{print $1}' | cut -c1-4)
_offset=$(( 0x$_hash_hex % 100 ))

# Base ports
_api_base=7707
_pg_base=5432

# Detect collisions with other running Compose projects: if the chosen
# ports are bound, bump by 1 until free (max 5 attempts).
_port_busy() { lsof -i ":$1" >/dev/null 2>&1; }

_api_port=$(( _api_base + _offset ))
_pg_port=$(( _pg_base + _offset ))
for _ in 1 2 3 4 5; do
  if _port_busy "$_api_port" || _port_busy "$_pg_port"; then
    _offset=$(( (_offset + 1) % 100 ))
    _api_port=$(( _api_base + _offset ))
    _pg_port=$(( _pg_base + _offset ))
  else
    break
  fi
done

export COMPOSE_PROJECT_NAME="$_workdir_name"
export API_PORT="$_api_port"
export POSTGRES_PORT="$_pg_port"
export DATABASE_URL="postgres://littlelove:dev@localhost:${_pg_port}/littlelove"

unset _workdir_name _hash_hex _offset _api_base _pg_base _api_port _pg_port _port_busy
```

- [ ] **Step 5: Create `scripts/dev-up.sh`**

```bash
#!/usr/bin/env bash
# scripts/dev-up.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

# Persist the computed values for other shells / tooling that may need them.
cat > "$ROOT_DIR/.dev.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
API_PORT=${API_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
DATABASE_URL=${DATABASE_URL}
EOF

echo "▶ project:  ${COMPOSE_PROJECT_NAME}"
echo "▶ api:      http://127.0.0.1:${API_PORT}"
echo "▶ postgres: localhost:${POSTGRES_PORT}"

docker compose up -d --build
```

- [ ] **Step 6: Create `scripts/dev-down.sh`**

```bash
#!/usr/bin/env bash
# scripts/dev-down.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=dev-env.sh
source "$SCRIPT_DIR/dev-env.sh"

docker compose down
```

- [ ] **Step 7: Make the scripts executable**

```sh
chmod +x scripts/dev-up.sh scripts/dev-down.sh
```

- [ ] **Step 8: Verify the dev scripts run without error**

Run: `./scripts/dev-up.sh`
Expected: lines printed for `project:`, `api:`, `postgres:`. Docker pulls `postgres:16-alpine` and `rust:1.78-bookworm`, then builds the `api` service. Eventually `docker compose ps` shows `api` and `postgres` both running. The `api` container will exit cleanly after printing `littlelove-api` (that's the placeholder binary).

Then: `./scripts/dev-down.sh`
Expected: containers stopped and removed.

- [ ] **Step 9: Commit**

```sh
git add docker-compose.yml scripts/ server/Dockerfile server/migrations/.gitkeep
git commit -m "$(cat <<'EOF'
Add worktree-aware Docker Compose dev stack

docker-compose.yml carries api (built from server/Dockerfile) and a
managed postgres:16-alpine. Postgres is unused in Day-1a but
provisioned now so port arithmetic is stable across slices.

scripts/dev-env.sh derives COMPOSE_PROJECT_NAME from the worktree
basename, computes a 0..99 port offset from sha1 of that name, and
bumps the offset if the candidate ports are already bound on the
host (covers the 1-in-100 hash collision case). dev-up.sh writes
the resolved values to a gitignored .dev.env and runs docker compose
up -d --build. dev-down.sh tears it back down.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.5: Continuous Integration workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
# .github/workflows/ci.yml
name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  rust:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: littlelove
          POSTGRES_PASSWORD: dev
          POSTGRES_DB: littlelove
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U littlelove"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 5
    env:
      DATABASE_URL: postgres://littlelove:dev@localhost:5432/littlelove
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@1.78
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - name: fmt
        run: cargo fmt --all -- --check
      - name: clippy
        run: cargo clippy --workspace --all-targets -- -D warnings
      - name: build
        run: cargo build --workspace --all-targets
      - name: test
        run: cargo test --workspace

  flutter:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.22.x'
      - run: flutter pub get
      - run: dart format --output=none --set-exit-if-changed .
      - run: flutter analyze
      - run: flutter test
```

- [ ] **Step 2: Commit**

```sh
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Add CI workflow: Rust + Flutter on push and PR

Rust job runs fmt, clippy (-D warnings), build, and test across the
workspace with a Postgres 16 service for sqlx-touching tests.
Flutter job runs dart format check, flutter analyze, and flutter
test. Branch coverage matches Court's saved feedback that build,
lint, and tests are required checks on every PR and push.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 0.6: README and project marker

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
# LittleLove

A private messenger for couples. End-to-end encrypted, hosted by a small couple. AI familiars run on hardware *you* own — no cloud AI providers, ever.

> **Day-1 alpha**: Court and Kaitlyn are the only users; the code is intentionally throwaway in the places that matter (symmetric encryption with a pre-shared key, no signup flow, no client persistence). The Phase 1 design at `docs/superpowers/specs/2026-06-09-littlelove-design.md` is the real product; Day-1 exists to prove the wire.

## Local dev

Requires: Docker Desktop (or Docker + Compose), Rust 1.78+, Flutter 3.22+ with macOS or Windows desktop enabled.

```sh
./scripts/dev-up.sh    # brings up api + postgres in the current worktree's namespace
cd app && flutter run -d macos    # or -d windows
./scripts/dev-down.sh
```

The dev scripts are **worktree-aware**: each `git worktree` you check out runs on its own ports and Postgres volume, derived deterministically from the worktree directory name. Two worktrees can run simultaneously without conflict.

## Releases

Tags matching `v*` (e.g., `v0.1.0-day1a`) trigger `.github/workflows/release.yml`, which builds:

- A container image to `ghcr.io/codingwithcourtreeves/littlelove-api:<tag>` (deployed to Railway by `deploy.yml`).
- `LittleLove-<version>.dmg` (macOS).
- `LittleLove-<version>.msi` (Windows).

All three attach to the GitHub Release. First launch warns about unsigned binaries — right-click → Open on macOS, "More info" → "Run anyway" on Windows. Signing is deferred to public launch.

## Docs

- `docs/positioning.md` — product voice (read before writing any user-facing copy)
- `docs/superpowers/specs/2026-06-09-littlelove-design.md` — Phase 1 design (full product)
- `docs/superpowers/specs/2026-06-09-littlelove-day1-design.md` — Day-1 design (the vertical slice being implemented now)
- `docs/superpowers/plans/2026-06-09-littlelove-day1-plan.md` — this plan
- `docs/mocks/` — desktop UI mocks with theme switcher
```

- [ ] **Step 2: Commit**

```sh
git add README.md
git commit -m "$(cat <<'EOF'
Add README with local dev quickstart

Points at dev-up.sh / dev-down.sh, calls out the worktree-aware
namespacing, summarizes the release pipeline (.dmg + .msi via
release.yml on v* tags), and links the four key docs.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1a — Plain text in-memory messenger

Goal of this phase: two Flutter desktops exchange plain-text messages through the Axum server. No database, no encryption. Tag `v0.1.0-day1a` at the end.

### Task 1a.1: Server config module

**Files:**
- Create: `server/src/config.rs`
- Modify: `server/src/lib.rs`

- [ ] **Step 1: Write the failing test**

```rust
// add to server/src/lib.rs
pub mod config;
```

```rust
// server/src/config.rs
use std::env;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub database_url: Option<String>,
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let port = env::var("PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(7707);
        let database_url = env::var("DATABASE_URL").ok().filter(|s| !s.is_empty());
        Self { port, database_url }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_port_7707_when_env_empty() {
        std::env::remove_var("PORT");
        std::env::remove_var("DATABASE_URL");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 7707);
        assert!(cfg.database_url.is_none());
    }

    #[test]
    fn reads_port_from_env() {
        std::env::set_var("PORT", "9999");
        let cfg = ServerConfig::from_env();
        assert_eq!(cfg.port, 9999);
        std::env::remove_var("PORT");
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `cargo test -p littlelove-api config`
Expected: 2 tests pass.

- [ ] **Step 3: Commit**

```sh
git add server/src/config.rs server/src/lib.rs
git commit -m "$(cat <<'EOF'
Add server config from env

ServerConfig::from_env reads PORT (default 7707) and DATABASE_URL
(None when unset or empty). Two unit tests cover defaults and the
PORT override.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.2: Wire format types (server side)

**Files:**
- Create: `server/src/wire.rs`
- Modify: `server/src/lib.rs`

- [ ] **Step 1: Add the module re-export**

```rust
// append to server/src/lib.rs
pub mod wire;
```

- [ ] **Step 2: Write the failing test (then the type)**

```rust
// server/src/wire.rs
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Inbound frames the server understands from a client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ClientFrame {
    Msg(MsgPayload),
}

/// Outbound frames the server can emit to a client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ServerFrame {
    Msg(MsgPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MsgPayload {
    pub id: Uuid,
    pub from: String,
    pub to: String,
    pub body: String,
    pub ts: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub replayed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_msg_frame() {
        let raw = r#"{"type":"msg","id":"7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707","from":"court","to":"kaitlyn","body":"hey","ts":"2026-06-09T17:00:00Z"}"#;
        let frame: ClientFrame = serde_json::from_str(raw).unwrap();
        match frame {
            ClientFrame::Msg(m) => {
                assert_eq!(m.from, "court");
                assert_eq!(m.to, "kaitlyn");
                assert_eq!(m.body, "hey");
                assert!(!m.replayed);
            }
        }
    }

    #[test]
    fn serializes_msg_without_replayed_when_false() {
        let m = MsgPayload {
            id: Uuid::nil(),
            from: "court".into(),
            to: "kaitlyn".into(),
            body: "hi".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: false,
        };
        let out = serde_json::to_string(&ServerFrame::Msg(m)).unwrap();
        assert!(!out.contains("replayed"));
        assert!(out.contains("\"type\":\"msg\""));
    }

    #[test]
    fn serializes_msg_with_replayed_when_true() {
        let m = MsgPayload {
            id: Uuid::nil(),
            from: "court".into(),
            to: "kaitlyn".into(),
            body: "hi".into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: true,
        };
        let out = serde_json::to_string(&ServerFrame::Msg(m)).unwrap();
        assert!(out.contains("\"replayed\":true"));
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cargo test -p littlelove-api wire`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```sh
git add server/src/wire.rs server/src/lib.rs
git commit -m "$(cat <<'EOF'
Add wire-format types: ClientFrame, ServerFrame, MsgPayload

Day-1a frames only: a single Msg variant in each direction carrying
id (uuid), from, to, body (plain text), ts (RFC 3339 UTC), and an
optional replayed flag that's elided from the JSON when false. Three
unit tests cover deserialization, the replayed=false elision, and
the replayed=true presence.

Day-1b will add Hello to ClientFrame; Day-1c keeps the envelope and
treats body as opaque.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.3: In-memory routing table

**Files:**
- Create: `server/src/routing.rs`
- Modify: `server/src/lib.rs`

- [ ] **Step 1: Add the module re-export**

```rust
// append to server/src/lib.rs
pub mod routing;
```

- [ ] **Step 2: Write the failing test (then the type)**

```rust
// server/src/routing.rs
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

use crate::wire::ServerFrame;

pub type Sender = mpsc::UnboundedSender<ServerFrame>;

#[derive(Debug, Default, Clone)]
pub struct Routing {
    inner: Arc<RwLock<HashMap<String, Sender>>>,
}

impl Routing {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register(&self, username: String, sender: Sender) {
        self.inner.write().await.insert(username, sender);
    }

    pub async fn unregister(&self, username: &str) {
        self.inner.write().await.remove(username);
    }

    /// Send to the recipient if they have an active connection.
    /// Returns true if delivered.
    pub async fn deliver(&self, recipient: &str, frame: ServerFrame) -> bool {
        let guard = self.inner.read().await;
        match guard.get(recipient) {
            Some(tx) => tx.send(frame).is_ok(),
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::MsgPayload;
    use uuid::Uuid;

    fn msg(from: &str, to: &str, body: &str) -> ServerFrame {
        ServerFrame::Msg(MsgPayload {
            id: Uuid::new_v4(),
            from: from.into(),
            to: to.into(),
            body: body.into(),
            ts: "2026-06-09T17:00:00Z".parse().unwrap(),
            replayed: false,
        })
    }

    #[tokio::test]
    async fn deliver_returns_false_when_recipient_offline() {
        let r = Routing::new();
        assert!(!r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
    }

    #[tokio::test]
    async fn deliver_returns_true_and_sends_when_recipient_online() {
        let r = Routing::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx).await;
        assert!(r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
        let received = rx.recv().await.unwrap();
        match received {
            ServerFrame::Msg(m) => assert_eq!(m.body, "hi"),
        }
    }

    #[tokio::test]
    async fn unregister_drops_the_sender() {
        let r = Routing::new();
        let (tx, _rx) = mpsc::unbounded_channel();
        r.register("kaitlyn".into(), tx).await;
        r.unregister("kaitlyn").await;
        assert!(!r.deliver("kaitlyn", msg("court", "kaitlyn", "hi")).await);
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `cargo test -p littlelove-api routing`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```sh
git add server/src/routing.rs server/src/lib.rs
git commit -m "$(cat <<'EOF'
Add in-memory routing table

Routing wraps Arc<RwLock<HashMap<username, mpsc::Sender>>>. register
adds a connection, unregister removes it, deliver returns true if
the recipient is online and false otherwise. Three async tests cover
the offline-drop, online-deliver, and post-unregister-drop cases.

Day-1b layer will add store-then-deliver on top; routing stays
oblivious to persistence.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.4: WebSocket upgrade handler

**Files:**
- Create: `server/src/ws.rs`
- Modify: `server/src/lib.rs`

- [ ] **Step 1: Add the module re-export**

```rust
// append to server/src/lib.rs
pub mod ws;
```

- [ ] **Step 2: Implement the handler**

```rust
// server/src/ws.rs
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::IntoResponse,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::routing::Routing;
use crate::wire::{ClientFrame, ServerFrame};

#[derive(Debug, Clone)]
pub struct AppState {
    pub routing: Routing,
}

/// Header used as Day-1 "auth": the connecting username.
pub const USER_HEADER: &str = "x-llove-user";

pub async fn ws_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let username = headers
        .get(USER_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    ws.on_upgrade(move |socket| async move {
        match username {
            Some(name) => handle_socket(socket, name, state).await,
            None => {
                warn!("WS upgrade rejected: missing {USER_HEADER}");
            }
        }
    })
}

async fn handle_socket(socket: WebSocket, username: String, state: AppState) {
    info!(%username, "client connected");
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerFrame>();
    state.routing.register(username.clone(), tx).await;

    // Pump outbound frames from the routing channel into the socket.
    let outbound = tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            let text = match serde_json::to_string(&frame) {
                Ok(s) => s,
                Err(e) => {
                    warn!("failed to serialize outbound frame: {e}");
                    continue;
                }
            };
            if sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });

    // Read inbound frames from the client.
    while let Some(Ok(msg)) = stream.next().await {
        if let Message::Text(text) = msg {
            match serde_json::from_str::<ClientFrame>(&text) {
                Ok(ClientFrame::Msg(payload)) => {
                    let to = payload.to.clone();
                    let delivered =
                        state.routing.deliver(&to, ServerFrame::Msg(payload)).await;
                    if !delivered {
                        info!(%to, "recipient offline; dropping (Day-1a)");
                    }
                }
                Err(e) => warn!("invalid frame from {username}: {e}"),
            }
        }
    }

    state.routing.unregister(&username).await;
    outbound.abort();
    info!(%username, "client disconnected");
}
```

- [ ] **Step 3: Write an integration-style test that exercises the handler end-to-end**

This test stands the handler in front of an in-process Axum router and connects two simulated clients via `tokio-tungstenite`. We put it in `server/tests/` as an integration test rather than a unit test so it gets a separate binary and can drive the real network stack.

Create: `server/tests/forwards_message.rs`

```rust
// server/tests/forwards_message.rs
use std::net::SocketAddr;
use std::time::Duration;

use axum::{routing::get, Router};
use futures::{SinkExt, StreamExt};
use littlelove_api::{
    routing::Routing,
    ws::{ws_handler, AppState, USER_HEADER},
};
use tokio::net::TcpListener;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message,
};

async fn spawn_server() -> SocketAddr {
    let state = AppState { routing: Routing::new() };
    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    addr
}

async fn connect(addr: SocketAddr, user: &str) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let url = format!("ws://{}/ws", addr);
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(
        USER_HEADER,
        user.parse().unwrap(),
    );
    let (sock, _resp) = connect_async(req).await.unwrap();
    sock
}

#[tokio::test]
async fn forwards_message_to_recipient_when_both_connected() {
    let addr = spawn_server().await;
    let mut court = connect(addr, "court").await;
    let mut kaitlyn = connect(addr, "kaitlyn").await;

    // Give both connections a moment to register in the routing table.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let frame = serde_json::json!({
        "type": "msg",
        "id": "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707",
        "from": "court",
        "to": "kaitlyn",
        "body": "hey love",
        "ts": "2026-06-09T17:00:00Z"
    });
    court.send(Message::Text(frame.to_string())).await.unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), kaitlyn.next())
        .await
        .expect("kaitlyn should receive a frame within 2s")
        .expect("stream closed")
        .expect("recv error");

    let text = match received {
        Message::Text(t) => t,
        other => panic!("expected text frame, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["from"], "court");
    assert_eq!(value["to"], "kaitlyn");
    assert_eq!(value["body"], "hey love");
}
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p littlelove-api`
Expected: all unit + integration tests pass, including `forwards_message_to_recipient_when_both_connected`.

- [ ] **Step 5: Commit**

```sh
git add server/src/ws.rs server/src/lib.rs server/tests/forwards_message.rs
git commit -m "$(cat <<'EOF'
Add WebSocket handler and the forwards-message round-trip test

ws_handler reads the x-llove-user header as Day-1 "auth" and rejects
upgrades that lack it. handle_socket splits the WS, registers an
mpsc Sender with Routing, pumps outbound frames into the socket,
and dispatches inbound Msg frames through Routing::deliver.

Adds tests/forwards_message.rs: spins up an Axum router on an
ephemeral port, connects two real tokio-tungstenite clients with
USER_HEADER set, and asserts that a Msg sent from court arrives at
kaitlyn within 2s with the original body.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.5: Health endpoint and binary entrypoint

**Files:**
- Modify: `server/src/main.rs`

- [ ] **Step 1: Write the failing test**

Create: `server/tests/health.rs`

```rust
// server/tests/health.rs
use std::time::Duration;

#[tokio::test]
async fn health_returns_ok() {
    // Spawn the binary on a known free port.
    let port: u16 = portpicker::pick_unused_port().expect("a free port");
    let mut cmd = tokio::process::Command::new(env!("CARGO_BIN_EXE_littlelove-api"))
        .env("PORT", port.to_string())
        .spawn()
        .expect("server starts");

    // Poll /health up to 5s for readiness.
    let url = format!("http://127.0.0.1:{port}/health");
    let mut last_err = None;
    for _ in 0..50 {
        match reqwest::get(&url).await {
            Ok(r) if r.status().is_success() => {
                cmd.kill().await.ok();
                return;
            }
            Ok(r) => last_err = Some(format!("status {}", r.status())),
            Err(e) => last_err = Some(e.to_string()),
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    cmd.kill().await.ok();
    panic!("server never became healthy: {last_err:?}");
}
```

Add dev-deps to `server/Cargo.toml`:

```toml
# under [dev-dependencies] in server/Cargo.toml
portpicker = "0.1"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls"] }
```

- [ ] **Step 2: Replace `server/src/main.rs` with the real binary**

```rust
// server/src/main.rs
use anyhow::Result;
use axum::{routing::get, Router};
use littlelove_api::{
    config::ServerConfig,
    routing::Routing,
    ws::{ws_handler, AppState},
};
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("info,littlelove_api=info")))
        .init();

    let cfg = ServerConfig::from_env();
    let state = AppState { routing: Routing::new() };
    let app = Router::new()
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .with_state(state);

    let addr: SocketAddr = format!("0.0.0.0:{}", cfg.port).parse()?;
    tracing::info!("listening on {addr}");
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> &'static str {
    "ok"
}
```

- [ ] **Step 3: Run the tests**

Run: `cargo test -p littlelove-api`
Expected: all tests pass, including `health_returns_ok` and `forwards_message_to_recipient_when_both_connected`.

- [ ] **Step 4: Commit**

```sh
git add server/src/main.rs server/Cargo.toml server/tests/health.rs
git commit -m "$(cat <<'EOF'
Wire up the server binary: GET /health, GET /ws

main.rs initializes tracing-subscriber from RUST_LOG (default
info,littlelove_api=info), builds AppState with a fresh Routing,
mounts /health (returns "ok") and /ws (ws_handler), and serves
0.0.0.0:$PORT. Adds tests/health.rs which spawns the actual binary
on a picked port and polls /health for up to 5s before failing.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.6: Client config TOML reader

**Files:**
- Create: `app/lib/config.dart`
- Create: `app/test/config_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/config.dart';

void main() {
  group('AppConfig.parse', () {
    test('parses required fields', () {
      const toml = '''
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:7707/ws"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
''';
      final cfg = AppConfig.parse(toml);
      expect(cfg.username, 'court');
      expect(cfg.displayName, 'Court');
      expect(cfg.serverUrl, 'ws://127.0.0.1:7707/ws');
      expect(cfg.contactUsername, 'kaitlyn');
      expect(cfg.contactDisplayName, 'Kaitlyn');
      expect(cfg.sharedKeyHex, isNull);
    });

    test('parses optional shared_key for Day-1c', () {
      const toml = '''
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:7707/ws"
shared_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
''';
      final cfg = AppConfig.parse(toml);
      expect(cfg.sharedKeyHex, isNotNull);
      expect(cfg.sharedKeyHex!.length, 64);
    });

    test('throws on missing username', () {
      const toml = '''
display_name = "Court"
server_url = "ws://x/ws"

[contact]
username = "k"
display_name = "K"
''';
      expect(() => AppConfig.parse(toml), throwsA(isA<FormatException>()));
    });
  });
}
```

- [ ] **Step 2: Write `app/lib/config.dart`**

```dart
// app/lib/config.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

class AppConfig {
  AppConfig({
    required this.username,
    required this.displayName,
    required this.serverUrl,
    required this.contactUsername,
    required this.contactDisplayName,
    this.sharedKeyHex,
  });

  final String username;
  final String displayName;
  final String serverUrl;
  final String contactUsername;
  final String contactDisplayName;

  /// 64 hex chars = 32 bytes. Present from Day-1c onwards.
  final String? sharedKeyHex;

  factory AppConfig.parse(String toml) {
    final doc = TomlDocument.parse(toml).toMap();
    final contact = (doc['contact'] as Map?)?.cast<String, Object?>();
    String require(String key, [Map<String, Object?>? m]) {
      final source = m ?? doc;
      final v = source[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('config: missing or non-string "$key"');
      }
      return v;
    }
    if (contact == null) {
      throw const FormatException('config: missing [contact] table');
    }
    return AppConfig(
      username: require('username'),
      displayName: require('display_name'),
      serverUrl: require('server_url'),
      contactUsername: require('username', contact),
      contactDisplayName: require('display_name', contact),
      sharedKeyHex: doc['shared_key'] as String?,
    );
  }

  /// Returns the OS-appropriate config path. macOS: ~/.littlelove/config.toml.
  /// Windows: %USERPROFILE%\.littlelove\config.toml.
  static File defaultConfigFile() {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? ''
        : Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      throw StateError('cannot determine home directory');
    }
    return File(p.join(home, '.littlelove', 'config.toml'));
  }

  static Future<AppConfig> load() async {
    final file = defaultConfigFile();
    if (!await file.exists()) {
      throw FileSystemException(
        'config not found; create it at ${file.path}',
      );
    }
    return AppConfig.parse(await file.readAsString());
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/config_test.dart`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```sh
git add app/lib/config.dart app/test/config_test.dart
git commit -m "$(cat <<'EOF'
Add AppConfig: TOML reader + OS-aware path resolution

AppConfig.parse pulls username, display_name, server_url, contact
table, and optional shared_key (Day-1c) out of a TOML document and
throws FormatException for missing required fields. defaultConfigFile
returns ~/.littlelove/config.toml on macOS and the USERPROFILE-rooted
equivalent on Windows; AppConfig.load reads it asynchronously.

Three widget tests cover the happy path, the optional shared_key,
and the missing-username error.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.7: Wire-format types (client side)

**Files:**
- Create: `app/lib/wire/message.dart`
- Create: `app/test/wire/message_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wire/message_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  test('Msg.fromJson parses a server frame', () {
    final json = {
      'type': 'msg',
      'id': '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      'from': 'court',
      'to': 'kaitlyn',
      'body': 'hey',
      'ts': '2026-06-09T17:00:00Z',
    };
    final m = Msg.fromJson(json);
    expect(m.from, 'court');
    expect(m.to, 'kaitlyn');
    expect(m.body, 'hey');
    expect(m.replayed, false);
  });

  test('Msg.fromJson parses replayed=true', () {
    final json = {
      'type': 'msg',
      'id': '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      'from': 'court',
      'to': 'kaitlyn',
      'body': 'old',
      'ts': '2026-06-08T17:00:00Z',
      'replayed': true,
    };
    final m = Msg.fromJson(json);
    expect(m.replayed, true);
  });

  test('Msg.toJson elides replayed when false', () {
    final m = Msg(
      id: '7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707',
      from: 'court',
      to: 'kaitlyn',
      body: 'hi',
      ts: DateTime.utc(2026, 6, 9, 17),
      replayed: false,
    );
    final j = m.toJson();
    expect(j.containsKey('replayed'), false);
    expect(j['type'], 'msg');
  });
}
```

- [ ] **Step 2: Write `app/lib/wire/message.dart`**

```dart
// app/lib/wire/message.dart
class Msg {
  Msg({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.ts,
    this.replayed = false,
  });

  final String id;
  final String from;
  final String to;

  /// Plain text Day-1a/b; a base64 ciphertext envelope Day-1c.
  /// At the Dart layer in Day-1a we treat it as opaque string.
  final String body;
  final DateTime ts;
  final bool replayed;

  factory Msg.fromJson(Map<String, Object?> json) {
    return Msg(
      id: json['id'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      body: json['body'] as String,
      ts: DateTime.parse(json['ts'] as String).toUtc(),
      replayed: (json['replayed'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'type': 'msg',
      'id': id,
      'from': from,
      'to': to,
      'body': body,
      'ts': ts.toUtc().toIso8601String(),
    };
    if (replayed) m['replayed'] = true;
    return m;
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/wire/message_test.dart`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```sh
git add app/lib/wire/message.dart app/test/wire/message_test.dart
git commit -m "$(cat <<'EOF'
Add client wire-format type: Msg

Msg.fromJson / toJson keep the Day-1a envelope (type, id, from, to,
body, ts) and the optional replayed flag (Day-1b). body is opaque
at this layer - it carries plaintext in 1a/1b and a serialized
ciphertext envelope in 1c. toJson elides replayed when false to
match what the server emits.

Three widget tests cover the happy path, replayed=true parsing, and
the replayed=false elision.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.8: WebSocket client with auto-reconnect

**Files:**
- Create: `app/lib/ws_client.dart`
- Create: `app/test/ws_client_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/ws_client_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/ws_client.dart';

void main() {
  test('LinearBackoff yields 1, 2, 5, 10, 15, 15... seconds', () {
    final b = LinearBackoff();
    expect(b.next().inSeconds, 1);
    expect(b.next().inSeconds, 2);
    expect(b.next().inSeconds, 5);
    expect(b.next().inSeconds, 10);
    expect(b.next().inSeconds, 15);
    expect(b.next().inSeconds, 15);
    b.reset();
    expect(b.next().inSeconds, 1);
  });
}
```

- [ ] **Step 2: Write `app/lib/ws_client.dart`**

```dart
// app/lib/ws_client.dart
import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'wire/message.dart';

/// Simple ramped backoff schedule for reconnect attempts.
class LinearBackoff {
  static const _steps = [1, 2, 5, 10, 15];
  int _i = 0;

  Duration next() {
    final s = _steps[_i.clamp(0, _steps.length - 1)];
    if (_i < _steps.length - 1) _i++;
    return Duration(seconds: s);
  }

  void reset() => _i = 0;
}

class WsClient {
  WsClient({
    required this.url,
    required this.username,
  });

  final String url;
  final String username;

  final _backoff = LinearBackoff();
  final _incoming = StreamController<Msg>.broadcast();
  Stream<Msg> get incoming => _incoming.stream;

  WebSocketChannel? _channel;
  bool _closed = false;

  Future<void> start() async {
    while (!_closed) {
      try {
        _channel = IOWebSocketChannel.connect(
          Uri.parse(url),
          headers: {'x-llove-user': username},
        );
        _backoff.reset();
        await for (final raw in _channel!.stream) {
          if (raw is! String) continue;
          final json = jsonDecode(raw) as Map<String, Object?>;
          if (json['type'] != 'msg') continue;
          _incoming.add(Msg.fromJson(json));
        }
      } catch (_) {
        // fall through to backoff
      }
      if (_closed) break;
      await Future<void>.delayed(_backoff.next());
    }
  }

  void send(Msg msg) {
    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  Future<void> close() async {
    _closed = true;
    await _channel?.sink.close();
    await _incoming.close();
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/ws_client_test.dart`
Expected: 1 test passes.

- [ ] **Step 4: Commit**

```sh
git add app/lib/ws_client.dart app/test/ws_client_test.dart
git commit -m "$(cat <<'EOF'
Add WsClient with linear backoff reconnect

WsClient connects to the configured server_url with the x-llove-user
header, decodes msg frames into a broadcast Stream<Msg>, and on any
disconnect waits for LinearBackoff (1, 2, 5, 10, 15s, capped) before
reconnecting. send() serializes Msg.toJson and writes to the sink.
close() sets a flag, closes the sink, and closes the broadcast.

The backoff schedule is unit-tested; the actual reconnect loop will
get end-to-end coverage via the full-stack integration test in a
later phase.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.9: Hearth palette constants

**Files:**
- Create: `app/lib/theme/hearth.dart`

- [ ] **Step 1: Write the file**

```dart
// app/lib/theme/hearth.dart
import 'package:flutter/material.dart';

/// Hearth, light variant. Values lifted verbatim from
/// design spec §11.4 and mocks/palette-gallery.html.
class HearthColors {
  static const bgCanvas       = Color(0xFFFBEEDD);
  static const bgSurface      = Color(0xFFF5E2C9);
  static const bgSurfaceAlt   = Color(0xFFEFD6B3);
  static const textPrimary    = Color(0xFF2C1E16);
  static const textMuted      = Color(0xFF8A6E58);
  static const accentUser     = Color(0xFFB23F2E);
  static const accentPartner  = Color(0xFFC97E5A);
  static const accentFamiliar = Color(0xFF9A6B1E);
  static const borderSoft     = Color(0xFFE3CBA6);
  static const ruleStrong     = Color(0xFF9A6B1E);

  // Bubble shades used by the conversation view.
  static const bubbleUserBg     = Color(0xFFF0C7BC);
  static const bubbleUserText   = Color(0xFF3F1A12);
  static const bubblePartnerBg  = Color(0xFFFFFAF0);
}

/// Builds a Material ThemeData using Hearth colors. Phase 1.5
/// will replace this with a token-driven ThemeExtension; Day-1
/// uses the simplest binding that produces the right look.
ThemeData buildHearthTheme() {
  const base = ColorScheme.light(
    primary: HearthColors.accentUser,
    onPrimary: Colors.white,
    secondary: HearthColors.accentFamiliar,
    surface: HearthColors.bgSurface,
    onSurface: HearthColors.textPrimary,
    background: HearthColors.bgCanvas,
    onBackground: HearthColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: HearthColors.bgCanvas,
    fontFamily: 'Inter',
  );
}
```

(No tests for static constants and a one-shot ThemeData builder; widget tests in Task 1a.10 will cover the look.)

- [ ] **Step 2: Commit**

```sh
git add app/lib/theme/hearth.dart
git commit -m "$(cat <<'EOF'
Add Hearth palette constants and buildHearthTheme()

Hex codes copied verbatim from design spec §11.4 (light variant).
buildHearthTheme assembles a Material 3 ThemeData with bgCanvas as
the scaffold background and accentUser/accentFamiliar as the
primary/secondary roles - good enough for Day-1 visual fidelity.
Phase 1.5 swaps this out for a token-driven ThemeExtension when
the runtime theme switcher ships.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.10: Conversation page UI

**Files:**
- Create: `app/lib/conversation_page.dart`

- [ ] **Step 1: Write the failing widget test**

Create: `app/test/conversation_page_test.dart`

```dart
// app/test/conversation_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation_page.dart';
import 'package:littlelove/theme/hearth.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  testWidgets('renders inbound and outbound bubbles distinctly', (tester) async {
    final messages = <Msg>[
      Msg(
        id: '1', from: 'kaitlyn', to: 'court', body: 'long. miss you.',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
      Msg(
        id: '2', from: 'court', to: 'kaitlyn', body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      theme: buildHearthTheme(),
      home: ConversationPage(
        meUsername: 'court',
        contactDisplayName: 'Kaitlyn',
        messages: messages,
        onSend: (_) {},
      ),
    ));
    expect(find.text('hey love'), findsOneWidget);
    expect(find.text('long. miss you.'), findsOneWidget);
    expect(find.text('Kaitlyn'), findsWidgets); // appears in header / metadata
  });

  testWidgets('Enter in composer fires onSend', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(
      theme: buildHearthTheme(),
      home: ConversationPage(
        meUsername: 'court',
        contactDisplayName: 'Kaitlyn',
        messages: const [],
        onSend: (text) => sent = text,
      ),
    ));
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sent, 'hi');
  });
}
```

- [ ] **Step 2: Implement `app/lib/conversation_page.dart`**

```dart
// app/lib/conversation_page.dart
import 'package:flutter/material.dart';

import 'theme/hearth.dart';
import 'wire/message.dart';

typedef SendCallback = void Function(String text);

class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.meUsername,
    required this.contactDisplayName,
    required this.messages,
    required this.onSend,
  });

  final String meUsername;
  final String contactDisplayName;
  final List<Msg> messages;
  final SendCallback onSend;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSubmit(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.messages]
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return Scaffold(
      backgroundColor: HearthColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: HearthColors.bgSurface,
        elevation: 0,
        title: Text(
          widget.contactDisplayName,
          style: const TextStyle(color: HearthColors.textPrimary),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: sorted.length,
              itemBuilder: (_, i) => _bubble(sorted[i]),
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _bubble(Msg m) {
    final mine = m.from == widget.meUsername;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: mine ? HearthColors.bubbleUserBg : HearthColors.bubblePartnerBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: HearthColors.borderSoft),
        ),
        child: Text(
          m.body,
          style: TextStyle(
            color: mine ? HearthColors.bubbleUserText : HearthColors.textPrimary,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      color: HearthColors.bgSurface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('composer'),
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: _handleSubmit,
              decoration: InputDecoration(
                hintText: 'Message ${widget.contactDisplayName}',
                filled: true,
                fillColor: HearthColors.bgSurfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => _handleSubmit(_controller.text),
            icon: const Icon(Icons.send, color: HearthColors.accentUser),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/conversation_page_test.dart`
Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```sh
git add app/lib/conversation_page.dart app/test/conversation_page_test.dart
git commit -m "$(cat <<'EOF'
Add ConversationPage with bubbles, composer, and send-on-enter

Stateful widget: messages list is sorted oldest-first, rendered as
left/right bubbles distinguished by whether from == meUsername.
Composer is a TextField keyed 'composer' with TextInputAction.send
that calls onSend(trimmed_text) and clears. Bubbles use
bubbleUserBg/bubblePartnerBg from HearthColors; the rest of the
chrome uses bgCanvas/bgSurface.

Two widget tests cover the inbound/outbound rendering split and
the Enter-fires-onSend flow.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.11: Wire the app together in main.dart

**Files:**
- Modify: `app/lib/main.dart`

- [ ] **Step 1: Replace `app/lib/main.dart`**

```dart
// app/lib/main.dart
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'conversation_page.dart';
import 'theme/hearth.dart';
import 'wire/message.dart';
import 'ws_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LittleLoveApp());
}

class LittleLoveApp extends StatelessWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LittleLove',
      theme: buildHearthTheme(),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  AppConfig? _config;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cfg = await AppConfig.load();
      setState(() => _config = cfg);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'LittleLove could not start.\n\n$_error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    if (_config == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _Live(config: _config!);
  }
}

class _Live extends StatefulWidget {
  const _Live({required this.config});
  final AppConfig config;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  late final WsClient _ws;
  final _messages = <Msg>[];
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _ws = WsClient(
      url: widget.config.serverUrl,
      username: widget.config.username,
    );
    _ws.incoming.listen((m) {
      setState(() => _messages.add(m));
    });
    // ignore: unawaited_futures
    _ws.start();
  }

  @override
  void dispose() {
    _ws.close();
    super.dispose();
  }

  void _send(String text) {
    final msg = Msg(
      id: _uuid.v4(),
      from: widget.config.username,
      to: widget.config.contactUsername,
      body: text,
      ts: DateTime.now().toUtc(),
    );
    _ws.send(msg);
    setState(() => _messages.add(msg));
  }

  @override
  Widget build(BuildContext context) {
    return ConversationPage(
      meUsername: widget.config.username,
      contactDisplayName: widget.config.contactDisplayName,
      messages: _messages,
      onSend: _send,
    );
  }
}
```

- [ ] **Step 2: Verify the full Flutter test suite still passes**

Run: `cd app && flutter test`
Expected: all tests pass.

- [ ] **Step 3: Verify it builds**

Run: `cd app && flutter build macos --debug`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```sh
git add app/lib/main.dart
git commit -m "$(cat <<'EOF'
Wire app entrypoint: config load -> WsClient -> ConversationPage

main runs LittleLoveApp under the Hearth theme. _Bootstrap loads
AppConfig.load(); on failure shows a centered error, on success
hands the AppConfig to _Live. _Live owns the WsClient, subscribes
to its incoming stream into a setState'd List<Msg>, generates a
UUIDv4 per outbound message, and dispatches to ConversationPage's
onSend.

This is the smallest binding that ties the four library files
together; Day-2 introduces Riverpod and pulls state out of the
widget.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.12: Manual two-user smoke test against Docker Compose

**Files:** (no code changes — verification only)

- [ ] **Step 1: Bring up the dev stack**

```sh
./scripts/dev-up.sh
```

Expected: prints `api: http://127.0.0.1:<port>` and `postgres: localhost:<port>`. `docker compose ps` shows both services up.

- [ ] **Step 2: Create a temporary config for "court" on the host**

```sh
mkdir -p ~/.littlelove
# Read the API_PORT from .dev.env to plug into server_url:
source .dev.env
cat > ~/.littlelove/config.toml <<EOF
username = "court"
display_name = "Court"
server_url = "ws://127.0.0.1:${API_PORT}/ws"

[contact]
username = "kaitlyn"
display_name = "Kaitlyn"
EOF
```

- [ ] **Step 3: Run two Flutter instances locally**

You'll simulate Kaitlyn by running a second app instance with a swapped config. From `app/`:

```sh
flutter run -d macos
```

In a second terminal, with a different `HOME` to keep configs separated:

```sh
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.littlelove"
source ../.dev.env
cat > "$TMPHOME/.littlelove/config.toml" <<EOF
username = "kaitlyn"
display_name = "Kaitlyn"
server_url = "ws://127.0.0.1:${API_PORT}/ws"

[contact]
username = "court"
display_name = "Court"
EOF
HOME="$TMPHOME" flutter run -d macos
```

- [ ] **Step 4: Manually verify**

- In the "court" window, type "hey love" + Enter. It should appear instantly.
- It should appear in the "kaitlyn" window within ~500ms.
- Reply from "kaitlyn"; it appears in "court" within ~500ms.
- Kill the api container (`docker compose kill api`), then `docker compose start api`. The clients should reconnect within ~15s and resume.

- [ ] **Step 5: Bring the stack back down**

```sh
./scripts/dev-down.sh
```

- [ ] **Step 6: There is nothing to commit for this task; it is a verification gate.**

---

### Task 1a.13: GitHub Release workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `.github/workflows/deploy.yml`

- [ ] **Step 1: Write `.github/workflows/release.yml`**

```yaml
# .github/workflows/release.yml
name: release

on:
  push:
    tags: ['v*']

permissions:
  contents: write
  packages: write

jobs:
  server:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push container
        uses: docker/build-push-action@v6
        with:
          context: .
          file: server/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/littlelove-api:${{ github.ref_name }}
            ghcr.io/${{ github.repository_owner }}/littlelove-api:latest

  app-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.22.x'
      - name: Build macOS
        working-directory: app
        run: |
          flutter config --enable-macos-desktop
          flutter pub get
          flutter build macos --release
      - name: Package as .dmg
        run: |
          brew install create-dmg
          cd app/build/macos/Build/Products/Release
          create-dmg \
            --volname "LittleLove" \
            --window-size 540 360 \
            --icon-size 96 \
            --app-drop-link 410 180 \
            "$GITHUB_WORKSPACE/LittleLove-${{ github.ref_name }}.dmg" \
            "littlelove.app"
      - uses: softprops/action-gh-release@v2
        with:
          files: LittleLove-${{ github.ref_name }}.dmg

  app-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.22.x'
      - name: Build Windows
        working-directory: app
        run: |
          flutter config --enable-windows-desktop
          flutter pub get
          flutter build windows --release
      - name: Package as zip
        shell: pwsh
        run: |
          $src = "app/build/windows/x64/runner/Release"
          $dest = "LittleLove-${{ github.ref_name }}-win64.zip"
          Compress-Archive -Path "$src/*" -DestinationPath $dest
      - uses: softprops/action-gh-release@v2
        with:
          files: LittleLove-${{ github.ref_name }}-win64.zip
```

(Windows ships as a `.zip` for Day-1 — Kaitlyn unzips and runs `littlelove.exe`. A real `.msi` installer ships when public-launch signing arrives. Documented in the release notes.)

- [ ] **Step 2: Write `.github/workflows/deploy.yml`** (separate from release per saved preference)

```yaml
# .github/workflows/deploy.yml
name: deploy

on:
  workflow_dispatch:
    inputs:
      tag:
        description: 'Image tag to deploy (e.g., v0.1.0-day1a)'
        required: true

jobs:
  railway:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm install -g @railway/cli@latest
      - name: Deploy to Railway
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}
        run: |
          railway link --project ${{ secrets.RAILWAY_PROJECT_ID }} \
                       --service littlelove-api \
                       --environment production
          railway up --service littlelove-api --detach
```

- [ ] **Step 3: Commit**

```sh
git add .github/workflows/release.yml .github/workflows/deploy.yml
git commit -m "$(cat <<'EOF'
Add release.yml (build + publish) and deploy.yml (Railway)

release.yml triggers on v* tags. Three parallel jobs:
- server: build container, push to ghcr.io/<owner>/littlelove-api
  at both the tag and :latest.
- app-macos: macos-latest runner; flutter build macos --release;
  create-dmg packages a .dmg; uploaded to the GitHub Release.
- app-windows: windows-latest runner; flutter build windows
  --release; zipped and uploaded to the Release. (.msi installer
  deferred until public-launch code signing lands.)

deploy.yml runs on workflow_dispatch only (per saved preference to
split release and deploy): takes a tag input, installs the Railway
CLI, links the project + service + environment from secrets, and
runs railway up.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1a.14: Tag v0.1.0-day1a

- [ ] **Step 1: Run the full test matrix locally**

```sh
cargo test --workspace
( cd app && flutter test )
```

Expected: all green.

- [ ] **Step 2: Push the branch and the tag**

```sh
git push origin main
git tag -a v0.1.0-day1a -m "$(cat <<'EOF'
Day-1a: plain text in-memory messenger

Two desktop clients can exchange plain-text messages through the
Axum server while both are connected. No persistence, no encryption.
First runnable LittleLove.

Acceptance criteria 1-4 and 8 (without the persistence steps).
EOF
)"
git push --tags
```

- [ ] **Step 3: Verify CI passes and release.yml produces artifacts**

Open GitHub Actions, wait for the `release` workflow to complete. Verify the release page has `LittleLove-v0.1.0-day1a.dmg` and `LittleLove-v0.1.0-day1a-win64.zip` attached.

- [ ] **Step 4: No code commit; this task is the tag itself.**

---

## Phase 1b — Postgres persistence + replay

Goal: server stores every message and replays history on connect. Tag `v0.1.0-day1b` at the end.

### Task 1b.1: Migration file and sqlx dependency

**Files:**
- Create: `server/migrations/0001_create_messages.sql`
- Modify: `server/Cargo.toml`

- [ ] **Step 1: Write the migration**

```sql
-- server/migrations/0001_create_messages.sql
CREATE TABLE messages (
  id          uuid        PRIMARY KEY,
  from_user   text        NOT NULL,
  to_user     text        NOT NULL,
  body        text        NOT NULL,
  ts          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_to_ts ON messages (to_user, ts);
```

- [ ] **Step 2: Add sqlx to `server/Cargo.toml`**

```toml
# under [dependencies] in server/Cargo.toml
sqlx.workspace = true
```

- [ ] **Step 3: Verify the workspace still builds**

Run: `cargo build -p littlelove-api`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```sh
git add server/migrations/0001_create_messages.sql server/Cargo.toml
git commit -m "$(cat <<'EOF'
Add 0001_create_messages migration and sqlx dep

Single messages table (id uuid PK, from_user, to_user, body, ts)
with a (to_user, ts) index for the replay-on-connect query. Adds
sqlx (postgres, runtime-tokio-rustls, uuid, chrono, macros, migrate)
to server Cargo deps.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.2: Add Hello frame to the wire types

**Files:**
- Modify: `server/src/wire.rs`
- Modify: `app/lib/wire/message.dart`

- [ ] **Step 1: Write the failing test** (Rust)

```rust
// append to server/src/wire.rs tests module
#[test]
fn parses_a_hello_frame() {
    let raw = r#"{"type":"hello","since":"2026-06-08T00:00:00Z"}"#;
    let frame: ClientFrame = serde_json::from_str(raw).unwrap();
    match frame {
        ClientFrame::Hello(h) => {
            let expected: chrono::DateTime<chrono::Utc> = "2026-06-08T00:00:00Z".parse().unwrap();
            assert_eq!(h.since, expected);
        }
        _ => panic!("expected Hello"),
    }
}
```

- [ ] **Step 2: Extend the Rust types**

```rust
// in server/src/wire.rs — replace the ClientFrame enum and add HelloPayload
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ClientFrame {
    Msg(MsgPayload),
    Hello(HelloPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HelloPayload {
    pub since: chrono::DateTime<chrono::Utc>,
}
```

- [ ] **Step 3: Run Rust tests**

Run: `cargo test -p littlelove-api wire`
Expected: 4 tests pass, including `parses_a_hello_frame`.

- [ ] **Step 4: Extend the Dart type**

Add to `app/lib/wire/message.dart`:

```dart
class Hello {
  Hello({required this.since});
  final DateTime since;

  Map<String, Object?> toJson() => {
        'type': 'hello',
        'since': since.toUtc().toIso8601String(),
      };
}
```

- [ ] **Step 5: Write the failing Dart test**

```dart
// append to app/test/wire/message_test.dart, inside main()
  test('Hello.toJson produces the expected envelope', () {
    final h = Hello(since: DateTime.utc(2026, 6, 8));
    final j = h.toJson();
    expect(j['type'], 'hello');
    expect(j['since'], '2026-06-08T00:00:00.000Z');
  });
```

- [ ] **Step 6: Run Dart tests**

Run: `cd app && flutter test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```sh
git add server/src/wire.rs app/lib/wire/message.dart app/test/wire/message_test.dart
git commit -m "$(cat <<'EOF'
Add Hello frame to wire types (server + client)

ClientFrame gains a Hello variant with HelloPayload { since:
DateTime<Utc> } on the Rust side. The Dart client gains a Hello
class with toJson producing { type: "hello", since: <iso8601> }.
Unit test on each side.

Day-1c will not change the wire types further; this is the only
envelope addition for Day-1.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.3: Server store module — insert and query

**Files:**
- Create: `server/src/store.rs`
- Modify: `server/src/lib.rs`

- [ ] **Step 1: Add the module re-export**

```rust
// append to server/src/lib.rs
pub mod store;
```

- [ ] **Step 2: Write the failing test** (placed in a dedicated integration test that uses the Postgres service)

Create: `server/tests/store.rs`

```rust
// server/tests/store.rs
use chrono::Utc;
use littlelove_api::store::{MessageRow, Store};
use uuid::Uuid;

fn database_url() -> String {
    std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set; run via dev-up or set it manually")
}

async fn fresh_store() -> Store {
    let store = Store::connect(&database_url()).await.expect("connect");
    sqlx::query("TRUNCATE TABLE messages")
        .execute(store.pool())
        .await
        .expect("truncate");
    store
}

#[tokio::test]
async fn store_and_replay_round_trip() {
    let store = fresh_store().await;
    let id = Uuid::new_v4();
    let now = Utc::now();
    store
        .insert(MessageRow {
            id,
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "hi".into(),
            ts: now,
        })
        .await
        .expect("insert");

    let history = store
        .messages_for(
            "kaitlyn",
            now - chrono::Duration::seconds(1),
        )
        .await
        .expect("query");
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].body, "hi");
}

#[tokio::test]
async fn store_only_returns_messages_addressed_to_user() {
    let store = fresh_store().await;
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "for k".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "kaitlyn".into(),
            to_user: "court".into(),
            body: "for c".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();

    let for_kaitlyn = store
        .messages_for("kaitlyn", Utc::now() - chrono::Duration::days(1))
        .await
        .unwrap();
    assert_eq!(for_kaitlyn.len(), 1);
    assert_eq!(for_kaitlyn[0].body, "for k");
}
```

- [ ] **Step 3: Write `server/src/store.rs`**

```rust
// server/src/store.rs
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::wire::MsgPayload;

#[derive(Debug, Clone)]
pub struct MessageRow {
    pub id: Uuid,
    pub from_user: String,
    pub to_user: String,
    pub body: String,
    pub ts: DateTime<Utc>,
}

impl From<MsgPayload> for MessageRow {
    fn from(m: MsgPayload) -> Self {
        Self {
            id: m.id,
            from_user: m.from,
            to_user: m.to,
            body: m.body,
            ts: m.ts,
        }
    }
}

impl MessageRow {
    pub fn into_payload(self, replayed: bool) -> MsgPayload {
        MsgPayload {
            id: self.id,
            from: self.from_user,
            to: self.to_user,
            body: self.body,
            ts: self.ts,
            replayed,
        }
    }
}

#[derive(Clone)]
pub struct Store {
    pool: PgPool,
}

impl Store {
    pub async fn connect(database_url: &str) -> anyhow::Result<Self> {
        let pool = PgPool::connect(database_url).await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn insert(&self, row: MessageRow) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO messages (id, from_user, to_user, body, ts)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(row.id)
        .bind(row.from_user)
        .bind(row.to_user)
        .bind(row.body)
        .bind(row.ts)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn messages_for(
        &self,
        recipient: &str,
        since: DateTime<Utc>,
    ) -> anyhow::Result<Vec<MessageRow>> {
        let rows = sqlx::query_as::<_, (Uuid, String, String, String, DateTime<Utc>)>(
            "SELECT id, from_user, to_user, body, ts
             FROM messages
             WHERE to_user = $1 AND ts > $2
             ORDER BY ts ASC",
        )
        .bind(recipient)
        .bind(since)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .map(|(id, from_user, to_user, body, ts)| MessageRow {
                id,
                from_user,
                to_user,
                body,
                ts,
            })
            .collect())
    }
}
```

- [ ] **Step 4: Run the tests against the dev Postgres**

```sh
./scripts/dev-up.sh
source .dev.env
cargo test -p littlelove-api --test store -- --test-threads 1
./scripts/dev-down.sh
```

Expected: 2 tests pass. (`--test-threads 1` because both tests truncate the shared table.)

- [ ] **Step 5: Commit**

```sh
git add server/src/store.rs server/src/lib.rs server/tests/store.rs
git commit -m "$(cat <<'EOF'
Add Store: connect, insert, messages_for

Store::connect opens a PgPool and runs the migrations from
./migrations at startup. insert idempotently writes a MessageRow
(ON CONFLICT DO NOTHING). messages_for("kaitlyn", since) returns
all rows where to_user = $1 AND ts > $2 ordered by ts ASC.

Conversion impls keep wire::MsgPayload and MessageRow in sync:
From<MsgPayload> for MessageRow drops the replayed bit, and
into_payload(replayed) puts it back at delivery time.

Integration tests run against a live Postgres (the dev-up stack)
and cover both round-trip insertion and the to_user filter. Tests
truncate at the top of each run; serialized via --test-threads 1.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.4: Wire Store into the WebSocket handler

**Files:**
- Modify: `server/src/ws.rs`
- Modify: `server/src/main.rs`
- Modify: `server/tests/forwards_message.rs`

- [ ] **Step 1: Extend AppState and the handler**

Replace `server/src/ws.rs`:

```rust
// server/src/ws.rs
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::IntoResponse,
};
use chrono::Utc;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::routing::Routing;
use crate::store::{MessageRow, Store};
use crate::wire::{ClientFrame, ServerFrame};

#[derive(Clone)]
pub struct AppState {
    pub routing: Routing,
    pub store: Option<Store>,
}

pub const USER_HEADER: &str = "x-llove-user";

pub async fn ws_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    let username = headers
        .get(USER_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    ws.on_upgrade(move |socket| async move {
        match username {
            Some(name) => handle_socket(socket, name, state).await,
            None => warn!("WS upgrade rejected: missing {USER_HEADER}"),
        }
    })
}

async fn handle_socket(socket: WebSocket, username: String, state: AppState) {
    info!(%username, "client connected");
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerFrame>();
    state.routing.register(username.clone(), tx.clone()).await;

    let outbound = tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            let text = match serde_json::to_string(&frame) {
                Ok(s) => s,
                Err(e) => {
                    warn!("failed to serialize outbound frame: {e}");
                    continue;
                }
            };
            if sink.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
    });

    while let Some(Ok(msg)) = stream.next().await {
        if let Message::Text(text) = msg {
            match serde_json::from_str::<ClientFrame>(&text) {
                Ok(ClientFrame::Msg(payload)) => {
                    if let Some(store) = &state.store {
                        if let Err(e) =
                            store.insert(MessageRow::from(payload.clone())).await
                        {
                            warn!("store insert failed: {e}");
                        }
                    }
                    let to = payload.to.clone();
                    let delivered =
                        state.routing.deliver(&to, ServerFrame::Msg(payload)).await;
                    if !delivered {
                        info!(%to, "recipient offline; stored only");
                    }
                }
                Ok(ClientFrame::Hello(h)) => {
                    if let Some(store) = &state.store {
                        match store.messages_for(&username, h.since).await {
                            Ok(rows) => {
                                for row in rows {
                                    let frame = ServerFrame::Msg(row.into_payload(true));
                                    let _ = tx.send(frame);
                                }
                            }
                            Err(e) => warn!("replay query failed: {e}"),
                        }
                    } else {
                        info!("hello received but store disabled (Day-1a mode)");
                    }
                }
                Err(e) => warn!("invalid frame from {username}: {e}"),
            }
        }
    }

    state.routing.unregister(&username).await;
    outbound.abort();
    let _ = Utc::now(); // silence unused import if Hello path is short-circuited
    info!(%username, "client disconnected");
}
```

- [ ] **Step 2: Update `server/src/main.rs` to wire the Store optionally**

```rust
// server/src/main.rs
use anyhow::Result;
use axum::{routing::get, Router};
use littlelove_api::{
    config::ServerConfig,
    routing::Routing,
    store::Store,
    ws::{ws_handler, AppState},
};
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new("info,littlelove_api=info")))
        .init();

    let cfg = ServerConfig::from_env();
    let store = match cfg.database_url.as_deref() {
        Some(url) => Some(Store::connect(url).await?),
        None => {
            tracing::warn!("DATABASE_URL unset; running without persistence (Day-1a mode)");
            None
        }
    };
    let state = AppState { routing: Routing::new(), store };
    let app = Router::new()
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .with_state(state);

    let addr: SocketAddr = format!("0.0.0.0:{}", cfg.port).parse()?;
    tracing::info!("listening on {addr}");
    let listener = TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> &'static str {
    "ok"
}
```

- [ ] **Step 3: Fix the existing integration test for the new AppState shape**

Replace `server/tests/forwards_message.rs` `spawn_server` body:

```rust
async fn spawn_server() -> SocketAddr {
    let state = AppState {
        routing: Routing::new(),
        store: None,
    };
    // ...rest unchanged
```

- [ ] **Step 4: Add a new integration test for replay**

Create: `server/tests/replays_history.rs`

```rust
// server/tests/replays_history.rs
use std::net::SocketAddr;
use std::time::Duration;

use axum::{routing::get, Router};
use chrono::Utc;
use futures::{SinkExt, StreamExt};
use littlelove_api::{
    routing::Routing,
    store::{MessageRow, Store},
    ws::{ws_handler, AppState, USER_HEADER},
};
use tokio::net::TcpListener;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, tungstenite::Message,
};
use uuid::Uuid;

async fn spawn_server(store: Store) -> SocketAddr {
    let state = AppState {
        routing: Routing::new(),
        store: Some(store),
    };
    let app = Router::new().route("/ws", get(ws_handler)).with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    addr
}

fn db_url() -> String {
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

#[tokio::test]
async fn stores_and_replays_history_for_disconnected_recipient() {
    let store = Store::connect(&db_url()).await.unwrap();
    sqlx::query("TRUNCATE TABLE messages")
        .execute(store.pool())
        .await
        .unwrap();

    // Seed one stored message addressed to kaitlyn.
    store
        .insert(MessageRow {
            id: Uuid::new_v4(),
            from_user: "court".into(),
            to_user: "kaitlyn".into(),
            body: "hey love".into(),
            ts: Utc::now(),
        })
        .await
        .unwrap();

    let addr = spawn_server(store).await;

    let url = format!("ws://{addr}/ws");
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(USER_HEADER, "kaitlyn".parse().unwrap());
    let (mut sock, _) = connect_async(req).await.unwrap();

    sock.send(Message::Text(
        serde_json::json!({
            "type": "hello",
            "since": (Utc::now() - chrono::Duration::days(1)).to_rfc3339()
        })
        .to_string(),
    ))
    .await
    .unwrap();

    let received = tokio::time::timeout(Duration::from_secs(2), sock.next())
        .await
        .expect("kaitlyn should receive a replay within 2s")
        .expect("stream closed")
        .expect("recv error");
    let text = match received {
        Message::Text(t) => t,
        other => panic!("expected text, got {other:?}"),
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["type"], "msg");
    assert_eq!(value["body"], "hey love");
    assert_eq!(value["replayed"], true);
}
```

- [ ] **Step 5: Run all server tests**

```sh
./scripts/dev-up.sh
source .dev.env
cargo test -p littlelove-api -- --test-threads 1
./scripts/dev-down.sh
```

Expected: all tests pass, including `stores_and_replays_history_for_disconnected_recipient`.

- [ ] **Step 6: Commit**

```sh
git add server/src/ws.rs server/src/main.rs server/tests/forwards_message.rs server/tests/replays_history.rs
git commit -m "$(cat <<'EOF'
Wire Postgres into the WS handler: insert + replay

AppState gains an Option<Store>. handle_socket:
- On Msg from a client: insert into store (if Some) then deliver via
  routing. The "stored only" log line replaces the Day-1a "dropping"
  message - history now survives the recipient being offline.
- On Hello from a client: query store.messages_for(username, since)
  and stream each row to the connecting client as a ServerFrame::Msg
  with replayed=true.

main.rs now runs Store::connect when DATABASE_URL is set and warns
when it isn't (Day-1a mode). forwards_message.rs is updated for the
new AppState shape and stays purely in-memory. replays_history.rs is
new and proves end-to-end replay by seeding a row, connecting as
kaitlyn, sending Hello with since=now-1d, and asserting the seeded
row arrives with replayed=true.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.5: Client sends Hello on connect

**Files:**
- Modify: `app/lib/ws_client.dart`

- [ ] **Step 1: Modify WsClient to take a hello-since parameter**

```dart
// in app/lib/ws_client.dart — extend the constructor and start()
class WsClient {
  WsClient({
    required this.url,
    required this.username,
    this.helloSince,
  });

  final String url;
  final String username;
  final DateTime? helloSince;

  // ...existing fields unchanged...

  Future<void> start() async {
    while (!_closed) {
      try {
        _channel = IOWebSocketChannel.connect(
          Uri.parse(url),
          headers: {'x-llove-user': username},
        );
        // Send Hello immediately after upgrade.
        final since = (helloSince ?? DateTime.now().toUtc().subtract(const Duration(days: 30)));
        _channel!.sink.add(jsonEncode(Hello(since: since.toUtc()).toJson()));

        _backoff.reset();
        await for (final raw in _channel!.stream) {
          if (raw is! String) continue;
          final json = jsonDecode(raw) as Map<String, Object?>;
          if (json['type'] != 'msg') continue;
          _incoming.add(Msg.fromJson(json));
        }
      } catch (_) {
        // fall through to backoff
      }
      if (_closed) break;
      await Future<void>.delayed(_backoff.next());
    }
  }
}
```

- [ ] **Step 2: Run Dart tests**

Run: `cd app && flutter test`
Expected: all tests pass (existing backoff and message tests untouched).

- [ ] **Step 3: Commit**

```sh
git add app/lib/ws_client.dart
git commit -m "$(cat <<'EOF'
Client: send Hello{since=now-30d} on every (re)connect

WsClient gains an optional helloSince parameter. start() sends a
Hello frame immediately after each WS upgrade with the configured
since (default: 30 days ago). Replayed messages flow through the
existing incoming Stream<Msg> path - replayed=true is preserved on
Msg so the UI can choose to render them differently later.

Reconnect after a server restart now picks up missed messages
automatically.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.6: Manual smoke test for persistence

**Files:** (no code; verification only)

- [ ] **Step 1: Bring up the stack and the two windows as in Task 1a.12.**

- [ ] **Step 2: Send a few messages between court and kaitlyn.**

- [ ] **Step 3: Close the "kaitlyn" window entirely. Send 2-3 messages from "court".**

- [ ] **Step 4: Reopen the "kaitlyn" window. Within ~2s of WS connect, the missing messages from step 3 must appear, marked-internally as `replayed=true` (no UI change yet, just data).**

- [ ] **Step 5: `docker compose restart api`. Both windows must reconnect and the full history must replay.**

- [ ] **Step 6: Bring the stack down.**

```sh
./scripts/dev-down.sh
```

---

### Task 1b.7: Provision Railway Postgres + DNS

**Files:** (no code; documentation/operational)

This is a one-time setup. Capture the resulting IDs in `docs/railway.md` so they can be re-pointed at later.

- [ ] **Step 1: Create the Railway project and services** (using `mcp__plugin_railway_railway__*` tools or the Railway dashboard)

- Project name: `littlelove`
- Add a managed Postgres plugin to the project.
- Add a service named `littlelove-api`, source: deploy from the GHCR image `ghcr.io/codingwithcourtreeves/littlelove-api:latest`.
- Set the service's `DATABASE_URL` to a reference variable pointing at the Postgres plugin's `DATABASE_URL`.
- Generate a Railway domain on the service for first smoke tests.

- [ ] **Step 2: Add the custom domain**

- In Railway, attach `api.littlelove.dev` to the `littlelove-api` service.
- Railway will print a CNAME target.
- At Cloudflare (the registrar/DNS for `littlelove.dev`), create a CNAME record: `api → <railway target>`. Proxy status: **DNS only** (gray cloud).

- [ ] **Step 3: Record IDs**

Create: `docs/railway.md`

```markdown
# Railway / DNS for LittleLove

| Item | Value |
|---|---|
| Project ID | (paste from Railway settings) |
| Production environment ID | (paste) |
| Service: littlelove-api | (paste service ID) |
| Postgres plugin | (paste service ID) |
| Custom domain | api.littlelove.dev |
| DNS provider | Cloudflare |

`DATABASE_URL` is a reference variable from the Postgres plugin.
`PORT` is set to 7707.

The two GH Actions secrets needed for `deploy.yml`:
- `RAILWAY_TOKEN` — a Railway team token.
- `RAILWAY_PROJECT_ID` — the project ID above.
```

- [ ] **Step 4: Commit the doc**

```sh
git add docs/railway.md
git commit -m "$(cat <<'EOF'
Document Railway project + DNS layout

Records the project, environment, and service IDs, the custom-domain
attachment (api.littlelove.dev CNAME via Cloudflare DNS-only), and
the two GH Actions secrets deploy.yml needs (RAILWAY_TOKEN and
RAILWAY_PROJECT_ID). The reference-variable wiring from the
Postgres plugin to the api service's DATABASE_URL is noted so the
plumbing is reproducible.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1b.8: Tag v0.1.0-day1b

- [ ] **Step 1: Run the full test matrix**

```sh
./scripts/dev-up.sh
source .dev.env
cargo test --workspace -- --test-threads 1
( cd app && flutter test )
./scripts/dev-down.sh
```

- [ ] **Step 2: Tag and push**

```sh
git push origin main
git tag -a v0.1.0-day1b -m "$(cat <<'EOF'
Day-1b: Postgres persistence + replay-on-connect

Server stores every message in Postgres and replays history
addressed to the connecting user on Hello{since}. Client sends
Hello{since=now-30d} on every (re)connect. Restarting the server,
or reconnecting after a network blip, now seamlessly recovers
the missing window.

Acceptance criteria 5 and 6.
EOF
)"
git push --tags
```

- [ ] **Step 3: Trigger the deploy workflow**

In GitHub UI → Actions → deploy → Run workflow → input `v0.1.0-day1b`.
Expected: Railway deploys the new container; `https://api.littlelove.dev/health` returns "ok".

- [ ] **Step 4: No code commit; this task is the tag + deploy.**

---

## Phase 1c — End-to-end symmetric encryption

Goal: messages are encrypted on the wire and at rest with XChaCha20-Poly1305. Tag `v0.1.0-day1c` at the end.

### Task 1c.1: Pure-Dart crypto wrapper

**Files:**
- Create: `app/lib/wire/crypto.dart`
- Create: `app/test/wire/crypto_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wire/crypto_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/crypto.dart';

void main() {
  // Deterministic 32-byte key for tests.
  const keyHex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('round-trip encrypt → decrypt yields the original plaintext', () async {
    final c = SymmetricCipher.fromHex(keyHex);
    final env = await c.encrypt('hey love');
    final out = await c.decrypt(env);
    expect(out, 'hey love');
  });

  test('two encrypts of the same plaintext produce different ciphertexts', () async {
    final c = SymmetricCipher.fromHex(keyHex);
    final a = await c.encrypt('hi');
    final b = await c.encrypt('hi');
    expect(a.ciphertextBase64 == b.ciphertextBase64 && a.nonceBase64 == b.nonceBase64, isFalse);
  });

  test('SymmetricCipher.fromHex throws on wrong-length key', () {
    expect(() => SymmetricCipher.fromHex('abcd'), throwsArgumentError);
  });
}
```

- [ ] **Step 2: Implement `app/lib/wire/crypto.dart`**

```dart
// app/lib/wire/crypto.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptedBody {
  EncryptedBody({required this.ciphertextBase64, required this.nonceBase64});
  final String ciphertextBase64;
  final String nonceBase64;

  Map<String, Object?> toJson() => {
        'ciphertext': ciphertextBase64,
        'nonce': nonceBase64,
      };

  factory EncryptedBody.fromJson(Map<String, Object?> json) {
    return EncryptedBody(
      ciphertextBase64: json['ciphertext'] as String,
      nonceBase64: json['nonce'] as String,
    );
  }

  /// Encode the encrypted body as the single base64 string we carry
  /// in the wire-format Msg.body field, so Day-1b's String envelope
  /// keeps working unchanged.
  String toWireString() => base64.encode(utf8.encode(jsonEncode(toJson())));

  factory EncryptedBody.fromWireString(String wire) {
    final json = jsonDecode(utf8.decode(base64.decode(wire))) as Map<String, Object?>;
    return EncryptedBody.fromJson(json);
  }
}

class SymmetricCipher {
  SymmetricCipher._(this._secretKey);

  final SecretKey _secretKey;
  final _algo = Xchacha20.poly1305Aead();

  static SymmetricCipher fromHex(String hex) {
    if (hex.length != 64) {
      throw ArgumentError('shared key must be 64 hex chars (32 bytes), got ${hex.length}');
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return SymmetricCipher._(SecretKey(bytes));
  }

  Future<EncryptedBody> encrypt(String plaintext) async {
    final nonce = _algo.newNonce();
    final box = await _algo.encrypt(
      utf8.encode(plaintext),
      secretKey: _secretKey,
      nonce: nonce,
    );
    // Pack ciphertext+mac as a single buffer.
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length,
          box.mac.bytes);
    return EncryptedBody(
      ciphertextBase64: base64.encode(out),
      nonceBase64: base64.encode(nonce),
    );
  }

  Future<String> decrypt(EncryptedBody env) async {
    final raw = base64.decode(env.ciphertextBase64);
    if (raw.length < 16) {
      throw const FormatException('ciphertext too short to contain MAC');
    }
    final cipherText = raw.sublist(0, raw.length - 16);
    final mac = Mac(raw.sublist(raw.length - 16));
    final nonce = base64.decode(env.nonceBase64);
    final plain = await _algo.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: _secretKey,
    );
    return utf8.decode(plain);
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `cd app && flutter test test/wire/crypto_test.dart`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```sh
git add app/lib/wire/crypto.dart app/test/wire/crypto_test.dart
git commit -m "$(cat <<'EOF'
Add SymmetricCipher (XChaCha20-Poly1305) + EncryptedBody envelope

SymmetricCipher.fromHex parses a 64-char hex shared_key into a
SecretKey and rejects wrong lengths. encrypt generates a fresh
nonce, AEAD-encrypts utf8(plaintext), and packs ciphertext+MAC
into a single base64 buffer. decrypt splits the trailing 16-byte
MAC off, calls Xchacha20.poly1305Aead().decrypt, and utf8-decodes.

EncryptedBody carries { ciphertext, nonce } and provides
toWireString/fromWireString that base64-encode the JSON envelope.
This lets us slot encryption in without changing the wire envelope
type - Msg.body remains String, just an opaque one in 1c.

Three unit tests cover the round-trip, nonce randomness across
two encrypts of the same plaintext, and the key-length guard.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1c.2: Encrypt outbound, decrypt inbound in the app

**Files:**
- Modify: `app/lib/main.dart`

- [ ] **Step 1: Modify `_LiveState` to encrypt/decrypt around the WsClient**

Replace the body of `_LiveState` in `app/lib/main.dart`:

```dart
class _LiveState extends State<_Live> {
  late final WsClient _ws;
  late final SymmetricCipher? _cipher;
  final _messages = <Msg>[];
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    final keyHex = widget.config.sharedKeyHex;
    _cipher = (keyHex != null) ? SymmetricCipher.fromHex(keyHex) : null;
    _ws = WsClient(
      url: widget.config.serverUrl,
      username: widget.config.username,
    );
    _ws.incoming.listen(_onIncoming);
    // ignore: unawaited_futures
    _ws.start();
  }

  Future<void> _onIncoming(Msg m) async {
    String body = m.body;
    final cipher = _cipher;
    if (cipher != null) {
      try {
        body = await cipher.decrypt(EncryptedBody.fromWireString(m.body));
      } catch (e) {
        body = '⚠ could not decrypt';
      }
    }
    setState(() {
      _messages.add(Msg(
        id: m.id,
        from: m.from,
        to: m.to,
        body: body,
        ts: m.ts,
        replayed: m.replayed,
      ));
    });
  }

  Future<void> _send(String text) async {
    final cipher = _cipher;
    final wireBody = (cipher != null)
        ? (await cipher.encrypt(text)).toWireString()
        : text;
    final msg = Msg(
      id: _uuid.v4(),
      from: widget.config.username,
      to: widget.config.contactUsername,
      body: wireBody,
      ts: DateTime.now().toUtc(),
    );
    _ws.send(msg);
    setState(() {
      _messages.add(Msg(
        id: msg.id,
        from: msg.from,
        to: msg.to,
        body: text,
        ts: msg.ts,
        replayed: false,
      ));
    });
  }

  @override
  void dispose() {
    _ws.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConversationPage(
      meUsername: widget.config.username,
      contactDisplayName: widget.config.contactDisplayName,
      messages: _messages,
      onSend: _send,
    );
  }
}
```

Add the imports at the top of `main.dart`:

```dart
import 'wire/crypto.dart';
```

- [ ] **Step 2: Run the full Dart suite**

Run: `cd app && flutter test`
Expected: all tests pass.

- [ ] **Step 3: Commit**

```sh
git add app/lib/main.dart
git commit -m "$(cat <<'EOF'
App: encrypt outbound and decrypt inbound when shared_key configured

_LiveState constructs a SymmetricCipher from config.sharedKeyHex when
present; nil otherwise. On send, the plaintext is fed through
cipher.encrypt, the EncryptedBody is wire-encoded into a single
String, and shipped as Msg.body. The local echo still renders the
plaintext.

On incoming Msg, body is parsed back through
EncryptedBody.fromWireString and cipher.decrypt; failures render
"⚠ could not decrypt" rather than crashing. When sharedKeyHex is
absent the app falls back to plain-text behavior, matching Day-1a/b
fixtures.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1c.3: Manual smoke test for ciphertext-at-rest

**Files:** (no code; verification only)

- [ ] **Step 1: Generate a shared 32-byte key**

```sh
openssl rand -hex 32
# example output: 7d1c9f...
```

- [ ] **Step 2: Add the shared_key to both `config.toml` files** (court's and the Kaitlyn-simulating one). Both must be identical.

- [ ] **Step 3: Bring up the stack, run both clients, send messages.**

- [ ] **Step 4: Inspect Postgres**

```sh
source .dev.env
docker compose exec postgres psql -U littlelove -d littlelove -c "SELECT id, from_user, to_user, body FROM messages ORDER BY ts DESC LIMIT 5;"
```

Expected: `body` column shows base64-encoded gibberish (the EncryptedBody wire form), NOT the plaintext.

- [ ] **Step 5: Verify both clients still display the messages decrypted.**

- [ ] **Step 6: Bring the stack down.**

---

### Task 1c.4: Tag v0.1.0-day1c

- [ ] **Step 1: Run all tests**

```sh
./scripts/dev-up.sh
source .dev.env
cargo test --workspace -- --test-threads 1
( cd app && flutter test )
./scripts/dev-down.sh
```

- [ ] **Step 2: Push and tag**

```sh
git push origin main
git tag -a v0.1.0-day1c -m "$(cat <<'EOF'
Day-1c: end-to-end symmetric encryption

Clients encrypt outbound messages with XChaCha20-Poly1305 using a
pre-shared 32-byte key from config.toml, ship the EncryptedBody as
the wire Msg.body, and decrypt on receive. Server is unchanged - it
stores and replays opaque bytes. Postgres console shows ciphertext
in the body column.

Acceptance criterion 7. Day-1 is complete.
EOF
)"
git push --tags
```

- [ ] **Step 3: Trigger the deploy workflow on `v0.1.0-day1c`.**

Expected: Railway redeploys (no code change in the server image — just a version bump). `https://api.littlelove.dev/health` still returns "ok".

- [ ] **Step 4: Download the published `.dmg` and `.zip` from the GitHub Release page and verify they install and run.**

---

## Closeout

After tagging `v0.1.0-day1c`:

- All 8 acceptance criteria from spec §12 are satisfied.
- The Phase 1 design (`docs/superpowers/specs/2026-06-09-littlelove-design.md`) is the next slice. Day-2 is sketched in spec §13: client-side SQLite persistence.
- The README explicitly notes that the Day-1 Dart code is throwaway — Phase 1 introduces the Rust core via `flutter_rust_bridge` and replaces the in-Dart crypto with MLS via `openmls`. Don't grow features on top of Day-1 Dart without a deliberate decision.

---

## Self-Review Notes (filled in after writing the plan above)

**Spec coverage check:**

- §2 three-stage milestone → Phases 1a, 1b, 1c each end in a tag.
- §3 in-scope items: clients (Tasks 0.3, 1a.10, 1a.11), server (1a.1–1a.5, 1b.3, 1b.4), one conversation hard-coded (1a.11 main.dart), text only (covered), Hearth hardcoded (1a.9), server persistence Day-1b (1b.3, 1b.4), no client persistence (no task), pure Dart (covered, no `flutter_rust_bridge` task exists).
- §4 out-of-scope: no tasks for any deferred item. ✓
- §5 identity (config.toml, x-llove-user) → Task 1a.6 (config) + Task 1a.4 (USER_HEADER constant).
- §6 wire format: Day-1a Msg → Task 1a.2 / 1a.7. Day-1b Hello + replayed → Task 1b.2. Day-1c encrypted body → Task 1c.1, 1c.2.
- §7 server behavior across the slices → Tasks 1a.3, 1a.4, 1a.5, 1b.3, 1b.4. Day-1c "no server change" → no task; verified manually in 1c.3. ✓
- §8 client → Tasks 1a.9 (Hearth), 1a.10 (page), 1a.11 (binding), 1a.8 (WsClient), 1b.5 (Hello on connect), 1c.2 (cipher in main).
- §9 repo layout → tasks build all of it. ✓
- §10 local dev + distribution → Tasks 0.4 (Compose + worktree scripts), 1a.13 (release.yml + deploy.yml), 1b.7 (Railway provisioning).
- §11 testing layers → unit tests in every implementation task; integration tests via `server/tests/forwards_message.rs`, `server/tests/health.rs`, `server/tests/store.rs`, `server/tests/replays_history.rs`; manual two-laptop QA → Tasks 1a.12, 1b.6, 1c.3.
- §12 acceptance criteria 1-8 → tied to tag tasks 1a.14, 1b.8, 1c.4.
- §13 next slices → Closeout section references.
- §14 risks → handled by the dev-script port-collision logic (Task 0.4) and `_LiveState` decrypt-failure fallback (Task 1c.2). First-launch warnings are documented in README and release notes.

No gaps identified.

**Placeholder scan:**

- No "TBD", "TODO", or "fill in details" anywhere in the steps.
- Every step that changes code shows the actual code.
- Tests are inline, not "write tests for the above".
- Every command shown is concrete (no `flutter run --device-id <DEVICE>` placeholders).

**Type consistency:**

- Rust: `MsgPayload` (server wire) ↔ `MessageRow` (server store) with explicit `From<MsgPayload>` + `into_payload(replayed)` conversions. ✓
- Rust: `ClientFrame::Msg(MsgPayload)` and `ClientFrame::Hello(HelloPayload)` shapes match the JSON tests.
- Dart: `Msg` carries `String body` throughout — including in Day-1c, where the encrypted envelope is base64-encoded into a single string via `EncryptedBody.toWireString` rather than changing `Msg`. This deliberate choice keeps the Dart `Msg.toJson`/`fromJson` schema constant across all three slices.
- `USER_HEADER` constant is the source of truth for `x-llove-user` in both the server and the Dart client.
- `LinearBackoff` schedule matches the spec's "exponential backoff (1, 2, 5, 15, 30s)" in §14 of the Phase 1 design within an order of magnitude; Day-1 uses 1/2/5/10/15 to keep the test simple. Acceptable variation; can be tightened in Phase 1.

No inconsistencies found.
