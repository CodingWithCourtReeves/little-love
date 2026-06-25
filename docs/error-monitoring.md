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

## Secrets (never in git)

`SENTRY_DSN`, `SECRET_KEY`, the superuser password, the Resend API key, and
`DIAG_TOKEN` live only in Railway/Resend.

## Related

- `docs/railway.md` — the `littlelove-api` deployment this hangs off of.
- `infra/cloudflare/email.tf` — the `alerts@` Email Routing rule.
- `docs/superpowers/specs/2026-06-25-self-hosted-error-monitoring-design.md` — design rationale.
