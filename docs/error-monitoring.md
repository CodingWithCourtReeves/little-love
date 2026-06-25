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

Redeploy. Absent `SENTRY_DSN`, reporting is a no-op (local/dev/CI). On boot the
server logs `error reporting enabled (self-hosted)` or, when unset,
`SENTRY_DSN unset; error reporting disabled`.

## 3. Alert delivery

`alerts@littlelove.dev` is both the sender (Resend-verified domain) and the
recipient. The `cloudflare_email_routing_rule.alerts` resource in
`infra/cloudflare/email.tf` forwards it to Court's Gmail. Apply with
`tofu apply` from `infra/cloudflare` (needs `CLOUDFLARE_API_TOKEN`). No new DNS
is needed for sending: `littlelove.dev` is already a verified Resend sending
domain (see `web/DEPLOY.md`).

## 4. Smoke test (`/__diag/error-test`)

Set `DIAG_TOKEN` (any random secret) on `littlelove-api`, redeploy, then:

    curl -i -H "X-Diag-Token: $DIAG_TOKEN" https://api.littlelove.dev/__diag/error-test

Expect HTTP 200, a new issue in the Bugsink `littlelove-server` project, and an
alert email from `alerts@littlelove.dev` in Gmail. Without the token (or with a
wrong one) the route returns 404. Leave `DIAG_TOKEN` unset in steady-state
operation to keep the route inert.

## What gets reported, and scrubbing

The server reports panics and `error!`-level events. `error!` is reserved for
genuine server faults (DB write/read failures, 500s, state-corruption paths);
expected-degraded conditions (feature env unset, rate limits, malformed client
frames, optional cleanup) stay at `warn!`/`info!` and ride along as breadcrumbs.

**Every payload to Bugsink is scrubbed at one chokepoint** (`server/src/scrub.rs`,
wired into both `before_send` and `before_breadcrumb`), so diagnostics stay
content-free and identifier-free per the privacy policy:

- `redact()` pattern-strips emails, account UUIDs/ULIDs, hex/base64 tokens,
  credentialed URIs (DSN/DB URLs), Postgres `Key (col)=(value)` detail, and
  prefixed API keys from all free text.
- Key-based redaction drops the value of any sensitive structured field
  (`username`, `account`, `token`, `email`, …) wholesale. This is why log call
  sites must log identifiers as **structured fields**
  (`warn!(username = %me.username, "…")`), never interpolated into the message
  string — the field value is redacted for Bugsink while local stdout logs keep
  it. The server only ever holds ciphertext for message *content*, so content
  cannot leak by construction; this scrubbing covers the remaining metadata.

When adding new logging: put identifiers in structured fields, never in the
message text, and add the field name to `SENSITIVE_KEYS` if it is identifying.

## Secrets (never in git)

`SENTRY_DSN`, `SECRET_KEY`, the superuser password, the Resend API key, and
`DIAG_TOKEN` live only in Railway/Resend.

## Related

- `docs/railway.md` — the `littlelove-api` deployment this hangs off of.
- `infra/cloudflare/email.tf` — the `alerts@` Email Routing rule.
- `docs/superpowers/specs/2026-06-25-self-hosted-error-monitoring-design.md` — design rationale.
