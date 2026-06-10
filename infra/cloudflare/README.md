# Cloudflare config (OpenTofu)

Manages DNS + email routing for `littlelove.dev`. State is local (gitignored).

## What this manages

- **`api.littlelove.dev` CNAME** → Railway. Gray cloud (proxy off) — see comment in `dns.tf`. Touching this is non-negotiable; orange-cloud would terminate your E2EE WSS traffic at Cloudflare's edge.
- **Cloudflare Email Routing** → forwards `hello@littlelove.dev` and `court@littlelove.dev` to the Gmail address in `forward_to_gmail`. The MX / TXT / SPF records that email routing needs are managed by Cloudflare itself (not declared here).

## What this does NOT touch

Zone settings (TLS mode, minimum TLS version, security level, etc.). With the `api` record proxied=false, those settings don't apply to traffic that matters. Keep them at Cloudflare defaults and don't introduce coupling.

## One-time setup

1. Install OpenTofu: `brew install opentofu` (already done on Court's box).
2. Create a Cloudflare API token (dashboard → My Profile → API Tokens → Create Token → Custom):
   - **Permissions**: `Zone:Read`, `DNS:Edit`, `Zone Settings:Edit`, `Account / Email Routing:Edit`
   - **Zone Resources**: include only `littlelove.dev`
3. Export it: `export CLOUDFLARE_API_TOKEN=...` (or add to `~/.zshrc` / direnv).
4. Copy `example.tfvars` to `terraform.tfvars` (gitignored) and fill in `account_id` + `railway_cname_target`.

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

## Future: remote state

When you want this on more than one machine, move state to Cloudflare R2 (S3-compatible). ~20 min of work. Don't bother until you need it.
