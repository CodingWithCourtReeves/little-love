# Cloudflare config (OpenTofu)

Manages DNS, email routing, and the R2 attachment bucket for `littlelove.dev`. State is local (gitignored).

## What this manages

- **`api.littlelove.dev` CNAME** → Railway. Gray cloud (proxy off) — see comment in `dns.tf`. Touching this is non-negotiable; orange-cloud would terminate your E2EE WSS traffic at Cloudflare's edge.
- **Cloudflare Email Routing** → forwards `hello@littlelove.dev` and `court@littlelove.dev` to the Gmail address in `forward_to_gmail`. The MX / TXT / SPF records that email routing needs are managed by Cloudflare itself (not declared here).
- **R2 bucket `littlelove-media`** (`r2.tf`) → stores the E2EE attachment ciphertext. No CORS config (the iOS client uses native HTTP, not a browser origin).

## What this does NOT touch

Zone settings (TLS mode, minimum TLS version, security level, etc.). With the `api` record proxied=false, those settings don't apply to traffic that matters. Keep them at Cloudflare defaults and don't introduce coupling.

## One-time setup

1. Install OpenTofu: `brew install opentofu` (already done on Court's box).
2. Create a Cloudflare API token (dashboard → My Profile → API Tokens → Create Token → Custom). It needs **both** Account- and Zone-scoped rows — one token can mix them:

   | Resource | Permission | Access | Covers |
   |---|---|---|---|
   | **Account** (this account) | `Workers R2 Storage` | Write | `r2.tf` bucket create/manage |
   | **Zone** (`littlelove.dev`) | `Zone` | Read | the `cloudflare_zone` data-source lookup |
   | **Zone** (`littlelove.dev`) | `DNS` | Edit | the `api` CNAME record |
   | **Zone** (`littlelove.dev`) | `Email Routing Rules` | Edit | email routing settings + rule |

   Gotchas the dashboard makes easy to get wrong:
   - **`Workers R2 Storage` is an *Account* permission** — it only appears when the row's first selector is set to Account, not Zone. (API name: "Workers R2 Storage Write".)
   - Pick **`DNS`** (a.k.a. "DNS Records"), **not** "DNS Settings" — the latter is zone-wide config and can't edit records.
   - Pick **`Email Routing Rules`** (Zone), **not** "Email Routing Addresses" (Account) — `email.tf` deliberately doesn't manage destination addresses.
   - **`Zone:Read` is required even though it feels redundant** with DNS — the zone *data source* needs it, and it's the most common omission.
3. Export it: `export CLOUDFLARE_API_TOKEN=...` (or add to `~/.zshrc` / direnv).
4. Copy `example.tfvars` to `terraform.tfvars` (gitignored) and fill in `account_id` + `railway_cname_target`.

> **Not the same as the app's R2 credentials.** The four `R2_*` env vars the API server reads (`R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / …) are an **S3 access key + secret**, created separately in **R2 → Manage R2 API Tokens → Object Read & Write** scoped to `littlelove-media`. That's a different credential type (S3 SigV4, not a Cloudflare bearer token) and Terraform never touches it. See `docs/railway.md`.

## First apply

```bash
cd infra/cloudflare
tofu init
tofu plan    # review the diff
tofu apply
```

`tofu apply` prints the API hostname and confirms email routing is on.

## Iterating

Edit a `.tf` file → `tofu plan` → `tofu apply`. Commit the `.tf` changes; never commit `*.tfvars` or `*.tfstate`.

## Importing existing records

If you've already created records by hand in the Cloudflare dashboard, import them before the first apply so Tofu doesn't try to recreate:

```bash
tofu import cloudflare_record.api <zone_id>/<record_id>
```

Get `<zone_id>` from the Cloudflare zone overview page (right sidebar); `<record_id>` from the dashboard URL when you click the record.

If you created the R2 bucket by hand (e.g. to avoid granting `Workers R2 Storage` to this token), import it too:

```bash
tofu import cloudflare_r2_bucket.media littlelove-media
```

## Future: remote state

When you want this on more than one machine, move state to Cloudflare R2 (S3-compatible). ~20 min of work. Don't bother until you need it.
