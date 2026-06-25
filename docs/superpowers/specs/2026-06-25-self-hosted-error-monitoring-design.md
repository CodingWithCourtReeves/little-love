# Self-hosted server-side error monitoring — design

**Issue:** [#40](https://github.com/CodingWithCourtReeves/little-love/issues/40)
**Date:** 2026-06-25
**Status:** Approved design, ready for implementation plan
**Scope of this PR:** Rust server only. The Flutter app side (SDK + scrubbing
+ opt-in) is a deliberate follow-up, tracked separately.

## Goal

Give us crash/error visibility for the Rust server without breaking the
headline promise that there are "no third parties." We self-host one
Sentry-API-compatible backend (Bugsink) on our own Railway infrastructure and
point the server's `sentry` crate at it. First-party diagnostics, not a third
party.

The server only ever holds **ciphertext**, so error reports cannot leak
plaintext by construction. That is what makes the server side low-risk and the
right first increment.

### "Sentry" here means the SDK, not the SaaS

This matters because "Sentry" names two different things:

- **Sentry the hosted SaaS (sentry.io)** — the third party. We do **not** use
  it. We never sign up and never send it anything. Using it is exactly what
  would break the "no third parties" promise.
- **The `sentry` crate (and later `sentry_flutter`)** — the open-source client
  SDK. It speaks the Sentry wire protocol (the "envelope" format) and sends to
  whatever DSN you configure. It has no opinion about the destination.

Bugsink is **Sentry-API-compatible**: it accepts that same envelope format. So
the `sentry` crate points its DSN at **our Bugsink instance** and the reports
land on our own Railway infrastructure. **Bugsink is the destination; the
`sentry` crate is the messenger.** We need both, and neither is the third-party
Sentry service. Using the official SDK (rather than hand-rolling HTTP) gives us
mature panic capture, batching, retries, and release/env tagging for free,
while keeping every report first-party.

```
sentry crate (our Rust server)  ──envelope──▶  Bugsink (our Railway box)
        DSN points here ───────────────────────▶  our server, our data
```

## Non-goals (this PR)

- No `sentry_flutter`, no app-side reporting, no breadcrumb/`beforeSend`
  scrubbing, no in-app opt-in toggle. The app is where the only plaintext
  exists; its scrubbing work deserves its own focused PR.
- No custom domain for the Bugsink instance (use the Railway-provided domain).
- No tracing/performance/APM. Errors and panics only.

## Decisions (locked)

| Question | Decision | Why |
|---|---|---|
| Backend | **Bugsink** | Single container + one DB. Lowest ops/cost for an alpha. |
| Image tag | **`bugsink/bugsink:2.2.2`** (pinned) | Soaked stable (2026-06-04). Never `:latest` — an ingest backend must not change under us. 2.3.0 (2026-06-23) is too fresh; bump later if we want CSP reports/sparklines. |
| Bugsink DB | **Dedicated Railway Postgres** (separate from the app DB) | Bugsink's install guide explicitly discourages SQLite on a platform volume (no WAL-mode guarantees). Isolates ops data from user data. |
| Server reporting | **Always-on when `SENTRY_DSN` is set** (no opt-in) | Server holds ciphertext only; nothing to scrub. Opt-in is an app-only concern. |
| Config gating | **Optional-feature pattern** (absent DSN → no-op) | Mirrors the existing R2/TURN pattern in `config.rs`; keeps local dev, tests, and CI silent. |
| Alert delivery | **Resend SMTP → `alerts@littlelove.dev` → Gmail** | `littlelove.dev` is already a verified Resend sending domain (the contact form sends from `noreply@littlelove.dev`). Recipient wired via a new Cloudflare Email Routing rule mirroring `privacy@`. |

## Architecture

```
                        Railway project (little-love)
  ┌─────────────────────────────────────────────────────────────┐
  │  littlelove-api (Rust)            bugsink (2.2.2)            │
  │   sentry crate ──── envelope ───▶  ingest  ───┐             │
  │   SENTRY_DSN env                              │             │
  │                                    bugsink-postgres (new)   │
  │                                               │             │
  └───────────────────────────────────────────────┼─────────────┘
                                                   │ new-issue email
                                       Resend SMTP │ (smtp.resend.com)
                                                   ▼
                            alerts@littlelove.dev (Cloudflare Email Routing)
                                                   │ forward
                                                   ▼
                                          Court's Gmail
```

## Components

### 1. Bugsink service on Railway

New Railway service `bugsink` in the existing little-love project, plus a new
managed Postgres for it.

Service env vars (set in Railway, none committed):

| Var | Value | Notes |
|---|---|---|
| `SECRET_KEY` | random ≥50 chars | Django secret. |
| `CREATE_SUPERUSER` | `alerts@littlelove.dev:<pw>` | First login + the notified user. |
| `BASE_URL` | `https://<service>.up.railway.app` | Bugsink builds self-links/DSNs from this. |
| `BEHIND_HTTPS_PROXY` | `True` | Running behind Railway's TLS terminator. |
| `PORT` | Railway-provided | Listen port. |
| `DATABASE_URL` | reference var → `bugsink-postgres` | Dedicated Postgres. |
| `EMAIL_HOST` | `smtp.resend.com` | Resend SMTP relay. |
| `EMAIL_PORT` | `465` | Implicit TLS. |
| `EMAIL_USE_SSL` | `True` | Port 465 = SSL. |
| `EMAIL_USE_TLS` | `False` | Mutually exclusive with SSL. |
| `EMAIL_HOST_USER` | `resend` | Resend's fixed SMTP username. |
| `EMAIL_HOST_PASSWORD` | `<RESEND_API_KEY>` | Secret. Reuse/scope a Resend key. |
| `DEFAULT_FROM_EMAIL` | `alerts@littlelove.dev` | Verified Resend sender on the domain. |

Inside Bugsink (one-time, via UI): create a project named **`littlelove-server`**.
That project yields the **DSN** used by the Rust server. The DSN is a secret;
it lives only as a Railway env var on `littlelove-api`, never in the repo.

### 2. Rust server integration (`server/`)

- **Cargo:** add `sentry` and `sentry-tracing` to `server/Cargo.toml`. Use a
  minimal feature set (panic + the parts needed for the default transport;
  drop the default `tower`/`tracing` extras we do not use). Pin exact versions
  and run `cargo update -p` as needed so `Cargo.lock` is reproducible.
- **Config (`server/src/config.rs`):** add to `ServerConfig`, following the
  R2/TURN optional pattern:
  - `sentry_dsn: Option<String>` from `SENTRY_DSN`
  - `sentry_environment: Option<String>` from `SENTRY_ENVIRONMENT`
    (default `"production"` only when a DSN is present)
  When `SENTRY_DSN` is absent the feature is entirely off.
- **Init (`server/src/main.rs`):** initialize the Sentry guard early (around
  the current `tracing_subscriber` setup, before the rest of bootstrap) and
  bind it to a variable held for the whole of `main` so the client is not
  dropped. Client options:
  - `release` from `CARGO_PKG_VERSION` (or a build-injected git sha)
  - `environment` from config
  - `send_default_pii = false`
  - default panic integration enabled
  - error-level `tracing` events forwarded as events via `sentry-tracing`
  Initialization order note: if holding the guard inside `#[tokio::main]`
  proves awkward (guard lifetime vs. the async runtime), fall back to a thin
  non-async `main` that builds the guard, then enters the Tokio runtime. The
  implementation plan will confirm which is cleaner once building.
- **Diagnostic route:** add `GET /__diag/error-test`, gated behind a
  `DIAG_TOKEN` env var. When `DIAG_TOKEN` is unset the route returns 404 (inert
  in any environment that does not opt in). When set, a request carrying the
  matching token (header) calls `sentry::capture_message(...)` (a synthetic,
  content-free message) and returns 200. This deterministically forces an event
  for the proof-of-alerting step and remains a future smoke test. It must never
  emit user data.
- **Logging hygiene:** the existing rule still holds — never log ciphertext
  blobs or any field that could carry content into an exception/log message.

- **Error placement + scrubbing (added during implementation):** the server had
  zero `error!` calls (all faults logged at `warn!`), so without this Bugsink
  would only ever see panics. Genuine faults (DB write/read failures returning
  500/"Internal", and the `mark_consumed` atomicity path) were elevated to
  `error!`; expected-degraded conditions stay `warn!`. Separately, the
  `sentry-tracing` layer ships `warn!`/`info!` as breadcrumbs and the server's
  logs carry user identifiers (handles, account ids) and DB error detail — which
  would leak into Bugsink and break the content-free promise. So a scrubbing
  chokepoint (`server/src/scrub.rs`) runs in both `before_send` and
  `before_breadcrumb`: pattern redaction (emails, UUIDs/ULIDs, hex/base64
  tokens, credentialed URIs, Postgres `(col)=(value)` detail, prefixed API keys)
  plus key-based redaction of sensitive structured fields. Identifiers are
  logged as structured fields so they survive in local stdout but are redacted
  on the way to Bugsink. This is the server-side counterpart to the deferred
  app-side scrubbing; see `docs/error-monitoring.md`.

### 3. Alerting wiring (`infra/cloudflare/`)

Add one resource mirroring the existing `privacy@` rule in `email.tf`
(provider is pinned `~> 4.50`, so use v4 `cloudflare_email_routing_rule`
syntax):

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

Add `alerts@${var.zone_name}` to the `forwarded_addresses` output in
`outputs.tf`. Apply with `tofu apply` near the end of implementation, just
before the end-to-end alert verification.

No new DNS for *sending* is required: `littlelove.dev` is already Resend-verified
(DKIM/SPF added during the contact-form setup, per `web/DEPLOY.md`), and Resend
verifies the whole domain, so `alerts@littlelove.dev` is already a valid sender.

### 4. Privacy copy (`web/`)

All edits ship in this PR. The honest distinction: we add **no** trackers,
analytics, behavioral profiling, ads, AI, or third parties; we add **first-party,
content-free crash diagnostics on our own servers**. So most claims stay
literally true; only the explicit "no crash-tracking on our servers" clause must
change.

**Must change** — `web/public/privacy/index.html:79-82`. Current:
> We do not include analytics, telemetry, crash-tracking, advertising, or
> AI/LLM processing in the app or on our servers. We verified this in our own
> source code, which is public. [...] we do not build advertising or behavioral
> profiles.

Replace the "crash-tracking" clause with honest wording, e.g.:
> We don't use third-party trackers, analytics, advertising, or AI. To fix
> bugs, our own servers record crash diagnostics on infrastructure we run
> ourselves. These never include message content, which our servers only ever
> see encrypted. Nothing in the app tracks you. We verified this in our own
> source code, which is public, and we do not build advertising or behavioral
> profiles.

(Exact wording finalized during implementation. No em dashes in shipped copy.)

**Reconcile for consistency** (light edits so nothing reads as a contradiction
with the above; the tracker/analytics/profiling claims themselves remain true):
- `web/public/privacy/index.html:36` — "We don't use analytics, trackers,
  advertising, or AI." Keep the spirit; ensure it reads as *third-party*
  trackers / analytics so it does not contradict the diagnostics disclosure.
- `web/public/index.html:145` — "No trackers. No analytics or behavioral
  profiling in the app or the server." Crash diagnostics are not analytics or
  behavioral profiling, so this can stay, but verify the "in the app or the
  server" phrasing does not imply "no diagnostics at all." Adjust if needed.

**Verified still true, left unchanged:** `web/public/index.html:8` and
`web/public/privacy/index.html:7` meta ("no ads, no AI, no VC"); the
"no third-party requests" font notes (`index.html:30-31`, `fonts.css:1`,
`README.md:72`); "No AI." (`index.html:146`); "No venture capital. No
advertising." (`index.html:265`). None make a crash claim.

**Re-verify after editing:** grep the site once more for `crash|tracker|
telemetry|analyt|behavioral|third.part|diagnostic` and confirm every remaining
claim is still accurate.

### 5. Deploy runbook (`docs/`)

New `docs/error-monitoring.md` (sibling of `docs/railway.md`) documenting, for
a future operator:
- Standing up the `bugsink` service + its Postgres on Railway, with the full
  env-var table above.
- Creating the `littlelove-server` project and retrieving the DSN.
- Setting `SENTRY_DSN` (+ `SENTRY_ENVIRONMENT`) on `littlelove-api`.
- The Resend SMTP settings and the `alerts@` Email Routing rule (cross-link
  `infra/cloudflare`).
- The `/__diag/error-test` smoke-test procedure.
- Explicit "secrets that live only in Railway / Resend, never in git" list.

## Secrets — never in the diff

DSN, `SECRET_KEY`, superuser password, and the Resend API key are all set in
Railway (or Resend) out of band. The PR is code + Terraform + docs only.

## Verification plan (the proof chain)

Run after deploy, reported step-by-step with evidence:

1. **Bugsink up:** service healthy on Railway; UI reachable at `BASE_URL`;
   `littlelove-server` project exists; DSN retrieved.
2. **Server reporting:** `littlelove-api` redeployed with `SENTRY_DSN` set;
   startup logs show Sentry enabled (and, with the DSN unset locally, show it
   disabled — proving the gate).
3. **Event ingested:** `GET /__diag/error-test` with the `DIAG_TOKEN` header →
   the synthetic event appears in the Bugsink `littlelove-server` project.
4. **Alert fired:** a new-issue notification email lands in Court's Gmail,
   sent from `alerts@littlelove.dev` via Resend and routed through Cloudflare.
5. **Gate holds:** confirm the route 404s when `DIAG_TOKEN` is unset, and that
   a server with no `SENTRY_DSN` reports nothing.

## Testing strategy

- **Rust unit/config tests:** assert `ServerConfig` leaves Sentry disabled when
  `SENTRY_DSN` is unset and enabled when set, mirroring existing R2/TURN config
  tests. Use the dedicated `littlelove_test` DB convention; never the dev DB.
- **No network in tests:** tests must not require a live Bugsink. The init path
  is exercised by config-level assertions; the actual ingest is proven by the
  manual verification chain above.
- **CI:** run `cargo fmt`, `cargo clippy`, and the full server test suite
  locally before pushing (per project convention — per-file checks miss CI
  failures). `tofu fmt`/`validate` on `infra/cloudflare`.

## Risks & mitigations

- **A `:latest` regression** → pinned `2.2.2`; bumps are deliberate.
- **SQLite-on-volume data loss** → dedicated Postgres instead.
- **Accidental plaintext in a report** → server holds ciphertext only;
  `send_default_pii = false`; logging-hygiene rule; the diagnostic route emits
  only synthetic content.
- **Diagnostic route abuse** → token-gated, 404 when the token env is unset.
- **DSN/secret leak** → never committed; Railway/Resend only.
- **Privacy claim drift** → full-site grep re-verified after the copy edit.

## Out of scope / follow-ups

- App-side: `sentry_flutter`, `beforeBreadcrumb`/`beforeSend` scrubbing, opt-in
  toggle, second privacy-copy pass describing opt-in app reporting.
- Optional custom domain (`bugsink.littlelove.dev`) via Cloudflare.
- Optionally codifying the existing Resend DKIM/SPF records into Terraform
  (currently dashboard-managed, like the inbound MX records — `email.tf`
  deliberately leaves Cloudflare-auto-managed records undeclared).
