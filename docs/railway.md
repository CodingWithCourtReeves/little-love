# Railway / DNS for LittleLove

This is the production hosting layout. Provisioning happens once via the Railway dashboard or `mcp__plugin_railway_railway__*`. Fill in the IDs below as the project gets created — they don't exist yet.

| Item | Value |
|---|---|
| Project ID | _TBD on first provision_ |
| Production environment ID | _TBD_ |
| Service: `littlelove-api` | _TBD_ |
| Postgres plugin | _TBD_ |
| Custom domain | `api.littlelove.dev` |
| DNS provider | Cloudflare |

## Provisioning steps

1. **Create the Railway project.** Name: `littlelove`.
2. **Add managed Postgres.** Use the standard Postgres template.
3. **Add the `littlelove-api` service.** Source: deploy from the Docker Hub image `docker.io/codingwithcourt/littlelove-api:latest`.
4. **Wire `DATABASE_URL`.** On the `littlelove-api` service, set `DATABASE_URL` as a *reference variable* pointing at the Postgres plugin's `DATABASE_URL`. Set `PORT=7707`.
5. **Custom domain.** In Railway, attach `api.littlelove.dev` to the service. Railway prints a CNAME target.
6. **Cloudflare DNS.** Add a CNAME record `api → <railway target>`. Proxy status: **DNS only** (gray cloud) — Railway terminates TLS itself; orange-cloud would double-proxy.

## GitHub Actions secrets

`deploy.yml` (workflow_dispatch) needs:

| Secret | Source |
|---|---|
| `RAILWAY_TOKEN` | Railway team token (Settings → Tokens) |
| `RAILWAY_PROJECT_ID` | The project ID above |

Without these set the deploy workflow will fail at `railway link`.

`release.yml` (workflow_dispatch) needs Docker Hub push credentials:

| Secret | Source |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub account (`codingwithcourt`) |
| `DOCKERHUB_TOKEN` | Docker Hub access token with write scope (Account Settings → Security) |

## Reference

- Phase 1 design `docs/superpowers/specs/2026-06-09-littlelove-design.md` §10.5 — the source-of-truth for the hosting choice.
- `.github/workflows/release.yml` builds + pushes the container; `.github/workflows/deploy.yml` runs the Railway CLI.
