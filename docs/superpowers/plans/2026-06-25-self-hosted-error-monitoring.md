# Self-hosted server-side error monitoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Rust server reports panics and errors to our own self-hosted, Sentry-API-compatible backend (Bugsink on Railway), with a proven new-issue email alert, and the privacy copy stays honest.

**Architecture:** Add the open-source `sentry` SDK to the Rust server, gated on `SENTRY_DSN` using the existing R2/TURN optional-feature pattern (absent → no-op). It sends to **our** Bugsink instance, not sentry.io. A token-gated diagnostic route forces a synthetic event to prove the pipeline. Alerts go out via Resend SMTP to `alerts@littlelove.dev`, routed to Gmail by a new Cloudflare Email Routing rule. Privacy copy is reconciled in the same change.

**Tech Stack:** Rust (axum 0.7, tokio, tracing), `sentry` + `sentry-tracing` crates, Bugsink `2.2.2` on Railway + dedicated Postgres, Resend SMTP, Cloudflare (Terraform/OpenTofu, provider `~> 4.50`).

**Design doc:** `docs/superpowers/specs/2026-06-25-self-hosted-error-monitoring-design.md`

## Global Constraints

- **Scope: server-side only.** No Flutter/app changes. App SDK + scrubbing + opt-in are a deferred follow-up.
- **"Sentry" = the SDK, not the SaaS.** We never use sentry.io. The `sentry` crate's DSN points at our Bugsink instance.
- **Optional-feature gating:** when `SENTRY_DSN` is unset/empty, error reporting is entirely off (local dev, tests, CI stay silent). Mirror the `r2_from_env` / `turn_from_env` shape in `server/src/config.rs`.
- **rustls only:** the server uses `reqwest` with `rustls-tls` and no native-tls/openssl anywhere. The `sentry` crate MUST be configured for the reqwest+rustls transport (`default-features = false`, no `native-tls`).
- **Image pin:** Bugsink `bugsink/bugsink:2.2.2`. Never `:latest`.
- **Bugsink DB:** dedicated Railway Postgres (not SQLite-on-volume).
- **Secrets never in the diff:** DSN, `SECRET_KEY`, superuser password, Resend API key live in Railway/Resend only.
- **No plaintext in reports:** server holds ciphertext only; `send_default_pii = false`; never log ciphertext or content; the diag route emits only synthetic, content-free text.
- **Copy rule:** no em dashes in any user-facing copy (use period/comma/colon/semicolon).
- **Pre-push checks:** `cargo fmt`, `cargo clippy`, full `cargo test` for server changes; `tofu fmt`/`validate` for infra. Use the `littlelove_test` DB convention, never the dev DB.

---

### Task 1: Add `sentry` deps + `SentryConfig` (gated, with tests)

**Files:**
- Modify: `server/Cargo.toml:16-40` (add deps)
- Modify: `server/src/config.rs` (add `SentryConfig`, field, builder, tests)

**Interfaces:**
- Produces: `littlelove_api::config::SentryConfig { dsn: String, environment: String }`; `ServerConfig.sentry: Option<SentryConfig>`; `ServerConfig::sentry_from_env() -> Option<SentryConfig>`.

- [ ] **Step 1: Add the crates to `server/Cargo.toml`.** Under `[dependencies]`, after the `serde_json.workspace = true` line, add (keep alphabetical-ish grouping consistent with the file):

```toml
sentry = { version = "0.34", default-features = false, features = ["backtrace", "contexts", "panic", "reqwest", "rustls"] }
sentry-tracing = "0.34"
```

Notes for the implementer:
- `default-features = false` + the explicit `reqwest`/`rustls` features select the reqwest transport over **rustls** (no native-tls/openssl), matching the project's TLS stack.
- If a newer `0.x` is the current release, use it, but keep `sentry` and `sentry-tracing` on the **same** minor version (they are released in lockstep). Confirm the `rustls` feature name still exists for that version.

- [ ] **Step 2: Add the failing config test.** In `server/src/config.rs`, inside `mod tests`, add three tests mirroring the existing TURN tests (env-driven, `#[serial]`):

```rust
    #[test]
    #[serial]
    fn sentry_config_present_when_dsn_set() {
        std::env::set_var("SENTRY_DSN", "https://pub@bugsink.example/1");
        std::env::remove_var("SENTRY_ENVIRONMENT");
        let cfg = ServerConfig::from_env();
        let s = cfg.sentry.expect("sentry config Some when DSN set");
        assert_eq!(s.dsn, "https://pub@bugsink.example/1");
        // Defaults to "production" when SENTRY_ENVIRONMENT is unset.
        assert_eq!(s.environment, "production");
        std::env::remove_var("SENTRY_DSN");
    }

    #[test]
    #[serial]
    fn sentry_environment_is_read() {
        std::env::set_var("SENTRY_DSN", "https://pub@bugsink.example/1");
        std::env::set_var("SENTRY_ENVIRONMENT", "staging");
        let s = ServerConfig::sentry_from_env().expect("sentry config Some");
        assert_eq!(s.environment, "staging");
        std::env::remove_var("SENTRY_DSN");
        std::env::remove_var("SENTRY_ENVIRONMENT");
    }

    #[test]
    #[serial]
    fn sentry_config_absent_when_dsn_missing() {
        std::env::remove_var("SENTRY_DSN");
        assert!(ServerConfig::sentry_from_env().is_none());
    }
```

- [ ] **Step 3: Run the tests, confirm they fail to compile.**

Run: `cargo test -p littlelove-api config::tests::sentry`
Expected: FAIL — `no field `sentry` on type `ServerConfig`` / `no function `sentry_from_env``.

- [ ] **Step 4: Implement `SentryConfig`.** In `server/src/config.rs`, add the struct after `TurnConfig` (before `ServerConfig`):

```rust
#[derive(Debug, Clone)]
pub struct SentryConfig {
    /// DSN of our self-hosted, Sentry-API-compatible backend (Bugsink). This
    /// points at our own infrastructure, never sentry.io.
    pub dsn: String,
    /// Deployment environment label (e.g. "production", "staging").
    /// Defaults to "production" when `SENTRY_ENVIRONMENT` is unset.
    pub environment: String,
}
```

Add the field to `ServerConfig` (after `turn`):

```rust
    pub turn: Option<TurnConfig>,
    pub sentry: Option<SentryConfig>,
```

Set it in `from_env` (after `let turn = ...`):

```rust
        let turn = Self::turn_from_env();
        let sentry = Self::sentry_from_env();
        Self {
            port,
            database_url,
            r2,
            apns,
            turn,
            sentry,
        }
```

Add the builder next to `turn_from_env` (make it `pub` to match `turn_from_env`, so the test can call it directly):

```rust
    pub fn sentry_from_env() -> Option<SentryConfig> {
        let get = |k: &str| env::var(k).ok().filter(|s| !s.is_empty());
        Some(SentryConfig {
            dsn: get("SENTRY_DSN")?,
            environment: get("SENTRY_ENVIRONMENT").unwrap_or_else(|| "production".to_string()),
        })
    }
```

- [ ] **Step 5: Run the tests, confirm they pass.**

Run: `cargo test -p littlelove-api config::tests::sentry`
Expected: PASS (3 tests). Then `cargo build -p littlelove-api` to confirm the new crates resolve over rustls.

- [ ] **Step 6: Commit.**

```bash
git add server/Cargo.toml server/Cargo.lock server/src/config.rs
git commit -m "feat(server): add gated SentryConfig + sentry crate (rustls) (#40)"
```

---

### Task 2: Initialize Sentry in `main.rs` (panics + error-level tracing)

**Files:**
- Modify: `server/src/main.rs:1-22` (imports, init order, guard)

**Interfaces:**
- Consumes: `ServerConfig.sentry: Option<SentryConfig>` (Task 1).
- Produces: a live Sentry hub for the process when `SENTRY_DSN` is set; `tracing::error!` events forwarded to Bugsink.

- [ ] **Step 1: Update imports.** At the top of `server/src/main.rs`, replace the lone `use tracing_subscriber::EnvFilter;` with:

```rust
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;
```

- [ ] **Step 2: Reorder bootstrap and init Sentry before the subscriber.** Replace the current opening of `main` (the `tracing_subscriber::fmt()...init();` block at lines 15-20 **and** the `let cfg = ServerConfig::from_env();` at line 22) with:

```rust
    // Read config first: Sentry needs the DSN before we build the subscriber,
    // and `from_env` does no logging.
    let cfg = ServerConfig::from_env();

    // Initialize our self-hosted error reporting. The guard must live for the
    // whole of `main`, so bind it to a named variable (NOT `let _ = ...`, which
    // would drop it immediately). Absent DSN => `None` => no-op. This sends to
    // our Bugsink instance, never sentry.io.
    let _sentry_guard = cfg.sentry.as_ref().map(|sc| {
        sentry::init((
            sc.dsn.as_str(),
            sentry::ClientOptions {
                release: sentry::release_name!(),
                environment: Some(sc.environment.clone().into()),
                send_default_pii: false,
                ..Default::default()
            },
        ))
    });

    // Build the tracing subscriber via the registry so we can attach the Sentry
    // layer (forwards `error!` events as Bugsink events, lower levels as
    // breadcrumbs) alongside the existing fmt + env-filter behavior.
    tracing_subscriber::registry()
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,littlelove_api=info")),
        )
        .with(tracing_subscriber::fmt::layer())
        .with(sentry_tracing::layer())
        .init();

    if _sentry_guard.is_some() {
        tracing::info!("error reporting enabled (self-hosted)");
    } else {
        tracing::info!("SENTRY_DSN unset; error reporting disabled");
    }
```

(The later `let store = match cfg.database_url...` block is unchanged — `cfg` is now declared just above it.)

- [ ] **Step 3: Verify it builds and the gate works locally.**

Run: `cargo build -p littlelove-api`
Expected: builds clean.

Run (DSN unset): `cargo run -p littlelove-api 2>&1 | head -5` then Ctrl-C.
Expected: log line `SENTRY_DSN unset; error reporting disabled` appears; server starts normally. This proves the no-op gate.

- [ ] **Step 4: Run the full server test suite (no regressions).**

Run: `cargo test -p littlelove-api`
Expected: PASS (existing tests + Task 1's, unchanged behavior).

- [ ] **Step 5: Commit.**

```bash
git add server/src/main.rs
git commit -m "feat(server): init self-hosted error reporting + sentry-tracing layer (#40)"
```

---

### Task 3: Token-gated `/__diag/error-test` route

**Files:**
- Create: `server/src/diag.rs`
- Modify: `server/src/lib.rs:1-16` (add `pub mod diag;`)
- Modify: `server/src/main.rs:97-120` (register the route)

**Interfaces:**
- Consumes: the live Sentry hub (Task 2) — `sentry::capture_message` is a global no-op when uninitialized.
- Produces: `littlelove_api::diag::error_test(headers: axum::http::HeaderMap) -> axum::http::StatusCode`.

- [ ] **Step 1: Write the failing test.** Create `server/src/diag.rs` with the handler stub-less test first (write the whole file but with a `todo!()` body so the test compiles and fails at runtime). Actually write the file fully in Step 3; here add the test module content you will keep:

```rust
//! Diagnostic endpoints. Inert unless explicitly enabled via env.

use axum::http::{HeaderMap, StatusCode};

/// `GET /__diag/error-test` forces a synthetic error event so we can verify the
/// error-monitoring pipeline end to end (event reaches Bugsink, alert email
/// fires). Gated behind `DIAG_TOKEN`:
///
/// - `DIAG_TOKEN` unset/empty  -> 404 (route is inert).
/// - set, caller's `X-Diag-Token` header missing or wrong -> 404 (don't reveal
///   the route exists).
/// - set + correct header -> capture a content-free message, return 200.
///
/// MUST NOT emit user data.
pub async fn error_test(headers: HeaderMap) -> StatusCode {
    let Some(expected) = std::env::var("DIAG_TOKEN").ok().filter(|s| !s.is_empty()) else {
        return StatusCode::NOT_FOUND;
    };
    let provided = headers
        .get("x-diag-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    if provided != expected {
        return StatusCode::NOT_FOUND;
    }
    sentry::capture_message(
        "diag: synthetic test event from /__diag/error-test",
        sentry::Level::Error,
    );
    StatusCode::OK
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn headers_with(token: Option<&str>) -> HeaderMap {
        let mut h = HeaderMap::new();
        if let Some(t) = token {
            h.insert("x-diag-token", t.parse().unwrap());
        }
        h
    }

    #[tokio::test]
    #[serial]
    async fn returns_404_when_diag_token_unset() {
        std::env::remove_var("DIAG_TOKEN");
        assert_eq!(error_test(headers_with(Some("anything"))).await, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    #[serial]
    async fn returns_404_when_header_missing_or_wrong() {
        std::env::set_var("DIAG_TOKEN", "s3cret");
        assert_eq!(error_test(headers_with(None)).await, StatusCode::NOT_FOUND);
        assert_eq!(error_test(headers_with(Some("nope"))).await, StatusCode::NOT_FOUND);
        std::env::remove_var("DIAG_TOKEN");
    }

    #[tokio::test]
    #[serial]
    async fn returns_200_when_token_matches() {
        std::env::set_var("DIAG_TOKEN", "s3cret");
        assert_eq!(error_test(headers_with(Some("s3cret"))).await, StatusCode::OK);
        std::env::remove_var("DIAG_TOKEN");
    }
}
```

- [ ] **Step 2: Wire the module and run the test to confirm it fails.** Add to `server/src/lib.rs`, keeping alphabetical order (after `pub mod config;`):

```rust
pub mod diag;
```

Run: `cargo test -p littlelove-api diag::tests`
Expected: at this point the file already contains the real implementation from Step 1, so if you wrote it verbatim the tests PASS. If you prefer a true red/green: temporarily replace the function body with `todo!()`, run to see FAIL (panics), then restore. Either way, end Step 2 with the body as shown.

- [ ] **Step 3: Register the route in `main.rs`.** In the `Router::new()` chain, add the diagnostic route right after the `/health` route:

```rust
        .route("/health", get(health))
        .route(
            "/__diag/error-test",
            get(littlelove_api::diag::error_test),
        )
```

- [ ] **Step 4: Build + run the full suite.**

Run: `cargo test -p littlelove-api` then `cargo build -p littlelove-api`
Expected: PASS / clean build.

- [ ] **Step 5: Commit.**

```bash
git add server/src/diag.rs server/src/lib.rs server/src/main.rs
git commit -m "feat(server): token-gated /__diag/error-test smoke route (#40)"
```

---

### Task 4: Reconcile privacy + marketing copy

**Files:**
- Modify: `web/public/privacy/index.html:36` and `:79-82`
- Modify: `web/public/index.html:145`

**Interfaces:** none (static copy).

- [ ] **Step 1: Rewrite the detailed "What we don't do" paragraph.** In `web/public/privacy/index.html`, replace lines 79-82:

Current:
```html
      We do not include analytics, telemetry, crash-tracking, advertising, or
      AI/LLM processing in the app or on our servers. We verified this in our own
      source code, which is public. We do not sell, rent, or share your personal
      information, and we do not build advertising or behavioral profiles.
```

New:
```html
      We don&rsquo;t use third-party trackers, analytics, advertising, or AI. To
      fix bugs, our own servers record crash diagnostics on infrastructure we run
      ourselves; these never include message content, which our servers only ever
      see encrypted, and you can ask us to turn yours off. We verified this in our
      own source code, which is public. We do not sell, rent, or share your
      personal information, and we do not build advertising or behavioral profiles.
```

- [ ] **Step 2: Reconcile the TL;DR bullet.** In the same file, replace line 36:

Current:
```html
        <li>We don&rsquo;t use analytics, trackers, advertising, or AI. We don&rsquo;t sell or share your data.</li>
```

New:
```html
        <li>We don&rsquo;t use third-party trackers, analytics, advertising, or AI. We keep only content-free crash diagnostics on our own servers to fix bugs, and we don&rsquo;t sell or share your data.</li>
```

- [ ] **Step 3: Reconcile the marketing landing negation.** In `web/public/index.html`, replace line 145:

Current:
```html
        <li><span class="negations__no">No</span> trackers. <em>No analytics or behavioral profiling in the app or the server. We checked the code.</em></li>
```

New:
```html
        <li><span class="negations__no">No</span> trackers. <em>No third-party analytics or behavioral profiling. Bug-fixing crash diagnostics stay on servers we run ourselves. We checked the code.</em></li>
```

- [ ] **Step 4: Re-verify no remaining claim is now false, and no em dashes were introduced.**

Run:
```bash
cd web && grep -rin -E "crash|tracker|telemetry|analyt|behavioral|no third|third.part|diagnostic" public/ README.md
grep -rn "—" web/public/privacy/index.html web/public/index.html
```
Expected: every match is consistent with "first-party content-free server crash diagnostics; no third-party trackers/analytics/profiling/ads/AI"; the em-dash grep returns nothing for the edited lines. Eyeball the meta descriptions (`index.html:8`, `privacy:7`: "no ads, no AI, no VC") and confirm they make no crash claim, so they stay.

- [ ] **Step 5: Commit.**

```bash
git add web/public/privacy/index.html web/public/index.html
git commit -m "copy(web): disclose first-party content-free server crash diagnostics (#40)"
```

---

### Task 5: Cloudflare Email Routing rule for `alerts@`

**Files:**
- Modify: `infra/cloudflare/email.tf` (add the rule)
- Modify: `infra/cloudflare/outputs.tf` (add to `forwarded_addresses`)

**Interfaces:** Terraform resource `cloudflare_email_routing_rule.alerts`. Provider is pinned `~> 4.50` — use v4 block syntax (matches the existing `privacy` rule exactly).

- [ ] **Step 1: Add the rule.** In `infra/cloudflare/email.tf`, after the `cloudflare_email_routing_rule "privacy"` block, add:

```hcl
resource "cloudflare_email_routing_rule" "alerts" {
  zone_id = data.cloudflare_zone.main.id
  name    = "alerts → gmail"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "alerts@${var.zone_name}"
  }

  action {
    type  = "forward"
    value = [var.forward_to_gmail]
  }

  depends_on = [cloudflare_email_routing_settings.main]
}
```

- [ ] **Step 2: Surface it in outputs.** In `infra/cloudflare/outputs.tf`, extend the `forwarded_addresses` list:

```hcl
output "forwarded_addresses" {
  value = [
    "privacy@${var.zone_name}",
    "alerts@${var.zone_name}",
  ]
  description = "Inbox aliases that forward to forward_to_gmail."
}
```

- [ ] **Step 3: Format + validate (no apply yet).**

Run:
```bash
cd infra/cloudflare && tofu fmt && tofu validate
```
Expected: `tofu fmt` leaves the files unchanged (or only normalizes whitespace); `tofu validate` reports `Success! The configuration is valid.` (A plan/apply needs `CLOUDFLARE_API_TOKEN` and happens in Task 7.)

- [ ] **Step 4: Commit.**

```bash
git add infra/cloudflare/email.tf infra/cloudflare/outputs.tf
git commit -m "infra(cloudflare): route alerts@littlelove.dev to Gmail for crash alerts (#40)"
```

---

### Task 6: Deploy runbook

**Files:**
- Create: `docs/error-monitoring.md`

**Interfaces:** none (docs). Cross-links `docs/railway.md` and `infra/cloudflare`.

- [ ] **Step 1: Write the runbook.** Create `docs/error-monitoring.md` covering, for a future operator:

```markdown
# Error monitoring (self-hosted)

We self-host a Sentry-API-compatible backend (Bugsink) so the server's error
reports stay first-party. The open-source `sentry` crate is the client; Bugsink
is our own destination. We never use sentry.io. App-side reporting is a separate,
later effort.

## 1. Bugsink service on Railway

In the existing little-love Railway project:

1. Add a **Postgres** database service (dedicated to Bugsink; do NOT reuse the
   app DB). Bugsink discourages SQLite on a platform volume.
2. Add a service from image `bugsink/bugsink:2.2.2` (pinned; never `:latest`).
3. Set env vars on the Bugsink service:

   | Var | Value |
   |---|---|
   | `SECRET_KEY` | random string, >= 50 chars |
   | `CREATE_SUPERUSER` | `alerts@littlelove.dev:<password>` |
   | `BASE_URL` | `https://<bugsink-service>.up.railway.app` |
   | `BEHIND_HTTPS_PROXY` | `True` |
   | `PORT` | Railway-provided port |
   | `DATABASE_URL` | reference variable -> the Bugsink Postgres |
   | `EMAIL_HOST` | `smtp.resend.com` |
   | `EMAIL_PORT` | `465` |
   | `EMAIL_USE_SSL` | `True` |
   | `EMAIL_USE_TLS` | `False` |
   | `EMAIL_HOST_USER` | `resend` |
   | `EMAIL_HOST_PASSWORD` | a Resend API key (secret) |
   | `DEFAULT_FROM_EMAIL` | `alerts@littlelove.dev` |

4. Open `BASE_URL`, log in as the superuser, create a project named
   `littlelove-server`. Copy its **DSN**.

## 2. Point the server at Bugsink

On the `littlelove-api` Railway service set:

- `SENTRY_DSN` = the DSN from step 1.4 (secret)
- `SENTRY_ENVIRONMENT` = `production`

Redeploy. Absent `SENTRY_DSN`, reporting is a no-op (local/dev/CI).

## 3. Alert delivery

`alerts@littlelove.dev` is both the sender (Resend-verified domain) and the
recipient. The `cloudflare_email_routing_rule.alerts` resource in
`infra/cloudflare/email.tf` forwards it to Court's Gmail. Apply with
`tofu apply` (needs `CLOUDFLARE_API_TOKEN`).

## 4. Smoke test (`/__diag/error-test`)

Set `DIAG_TOKEN` (any random secret) on `littlelove-api`, redeploy, then:

    curl -i -H "X-Diag-Token: $DIAG_TOKEN" https://api.littlelove.dev/__diag/error-test

Expect HTTP 200, a new issue in the Bugsink `littlelove-server` project, and an
alert email from `alerts@littlelove.dev` in Gmail. Without the token the route
returns 404. Leave `DIAG_TOKEN` unset in normal operation to keep it inert.

## Secrets (never in git)

`SENTRY_DSN`, `SECRET_KEY`, the superuser password, the Resend API key, and
`DIAG_TOKEN` live only in Railway/Resend.
```

- [ ] **Step 2: Commit.**

```bash
git add docs/error-monitoring.md
git commit -m "docs: add self-hosted error-monitoring deploy runbook (#40)"
```

---

### Task 7: Provision Bugsink + prove the alert end to end

**Files:** none (live infra + verification). Requires Railway access (Railway MCP or dashboard), the Resend API key, and `CLOUDFLARE_API_TOKEN` for the tofu apply.

**Interfaces:** Consumes everything above. Produces: a running Bugsink, a live `SENTRY_DSN` on `littlelove-api`, and captured evidence of the proof chain.

> This task is ops, not code. Each step is a checkpoint with observable evidence. Pause for Court where access/secrets are needed.

- [ ] **Step 1: Deploy Bugsink + Postgres** on Railway per runbook §1. Evidence: Bugsink UI loads at `BASE_URL`; `littlelove-server` project created; DSN copied.
- [ ] **Step 2: Apply the Cloudflare rule.** `cd infra/cloudflare && tofu apply` (with `CLOUDFLARE_API_TOKEN`). Evidence: `alerts@littlelove.dev` appears under Email Routing; send a test mail to it and confirm it lands in Gmail.
- [ ] **Step 3: Configure + redeploy the server.** Set `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `DIAG_TOKEN` on `littlelove-api`; redeploy. Evidence: deploy logs show `error reporting enabled (self-hosted)`.
- [ ] **Step 4: Fire the smoke test.** `curl -i -H "X-Diag-Token: $DIAG_TOKEN" https://api.littlelove.dev/__diag/error-test`. Evidence: HTTP 200.
- [ ] **Step 5: Confirm the proof chain.** Evidence: the synthetic event is visible in Bugsink `littlelove-server`, AND a new-issue alert email from `alerts@littlelove.dev` arrived in Gmail.
- [ ] **Step 6: Confirm the gate.** `curl -i https://api.littlelove.dev/__diag/error-test` with no/wrong token returns 404. Note in the PR that `DIAG_TOKEN` should be removed/left unset for steady-state.

---

## Self-Review

**Spec coverage:**
- Backend choice/pin/DB → Task 7 §1 + runbook (Task 6) + Global Constraints. ✓
- Rust SDK gated on DSN (R2/TURN pattern) → Task 1. ✓
- Init + panics + error-level tracing → Task 2. ✓
- Diagnostic test route → Task 3. ✓
- Alert delivery via Resend + Email Routing rule → Task 5 (code) + Task 7 §2 (apply). ✓
- Privacy copy (the mandatory edit + 2 reconciliations + re-verify) → Task 4. ✓
- Deploy runbook + secrets handling → Task 6. ✓
- Proof chain → Task 7. ✓
- "Sentry SDK vs SaaS" clarity → Global Constraints + runbook intro. ✓

**Placeholder scan:** no TBD/TODO; the one "finalize wording" note in the spec is resolved to concrete copy here. The only `todo!()` mention is an optional red/green technique in Task 3 Step 2, with the real body given. ✓

**Type consistency:** `SentryConfig { dsn, environment }`, `ServerConfig.sentry`, `sentry_from_env()`, and `diag::error_test(HeaderMap) -> StatusCode` are used identically wherever referenced. Env vars (`SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `DIAG_TOKEN`, the Bugsink `EMAIL_*`) match between config, main, diag, and the runbook. ✓
