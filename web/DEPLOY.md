# Deploying littlelove.dev (Cloudflare Pages)

The site is static (`public/`) plus one Pages Function (`functions/api/contact.js`).
No build step. Run all `wrangler` commands from this `web/` directory (it holds
`wrangler.jsonc`).

## 0. One-time: install wrangler + sign in

```sh
brew install cloudflare-wrangler     # or: npm i -g wrangler
wrangler login                       # opens a browser; or export CLOUDFLARE_API_TOKEN
```

If you use a token instead of `wrangler login`, it needs the account-scoped
**Cloudflare Pages: Edit** permission (separate from the Terraform token).

## 1. Test locally (with the Function)

Put a real Resend key in `web/.dev.vars` (gitignored), then:

```sh
cd web
wrangler pages dev          # serves public/ + runs functions/ at http://localhost:8788
```

This is the only way to exercise `POST /api/contact` locally (a plain static
server can't run the Function).

## 2. Create the project (first time only)

```sh
wrangler pages project create littlelove --production-branch main
```

## 3. Set the secret

```sh
wrangler pages secret put RESEND_API_KEY --project-name littlelove
```

`CONTACT_TO` / `CONTACT_FROM` are non-secret and already set in `wrangler.jsonc`
(`vars`), so they deploy automatically.

## 4. Deploy

```sh
cd web
wrangler pages deploy            # reads wrangler.jsonc; deploys public/ + functions/
```

This gives a `*.pages.dev` URL. Verify the site, then check the Function:
`curl -X POST https://<deployment>.pages.dev/api/contact -H 'content-type: application/json' -d '{"email":"you@example.com","message":"hi"}'`

## 5. Verify the sender domain in Resend (REQUIRED, easy to forget)

Until `littlelove.dev` is verified in Resend, **every contact-form send is
rejected**. In the Resend dashboard add the domain; it gives you DKIM / SPF /
return-path DNS records. Add those to Cloudflare DNS (codify them in
`infra/cloudflare/` once you have the exact records, or add by hand). Then the
`CONTACT_FROM` (`noreply@littlelove.dev`) sender works.

## 6. Attach the apex custom domain `littlelove.dev`

There is no wrangler command for this. Two options:

- **Dashboard:** Pages project -> Custom domains -> add `littlelove.dev`.
  Cloudflare auto-creates the apex DNS (the zone is already here).
- **Terraform (infra-as-code):** add a `cloudflare_pages_project` +
  `cloudflare_pages_domain` to `infra/cloudflare/`. Keeps the whole deploy
  declarative. (Do NOT also add a manual apex DNS record; the domain attach
  manages it, and a hand-rolled record would conflict.)

## 7. Apply the edge rate limit

`infra/cloudflare/ratelimit.tf` caps `POST /api/contact`. Apply it from your
**main checkout** (state + tfvars live there, not in a worktree):

```sh
cd ~/projects/little-love/infra/cloudflare
tofu plan && tofu apply
```

The token may need **Zone -> WAF -> Edit** added (see the note in `ratelimit.tf`).

## 8. Confirm universal links + retire the old API routes

- Check the AASA serves as JSON: `curl -sI https://littlelove.dev/.well-known/apple-app-site-association | grep -i content-type` should show `application/json` (set by `public/_headers`).
- Tap a `https://littlelove.dev/pair/<code>` link on a device with the app installed; it should open the app. Without the app, it shows the `/pair/` fallback.
- Once the apex serves the AASA + `/pair` fallback from Pages, remove the now-dead `apple_app_site_association` and `pair_landing` handlers from `server/src/well_known.rs` (and their routes in `server/src/main.rs`).

## Updating later

Edit files in `public/` (or `functions/`) -> `wrangler pages deploy`. Or connect
the GitHub repo in the Pages dashboard for auto-deploy on push to `main`
(build command: none, output dir: `web/public`, root: repo root).
