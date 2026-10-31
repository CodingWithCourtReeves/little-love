# littlelove.dev marketing site

Static site (plain HTML/CSS/JS) for the apex domain **`littlelove.dev`**, hosted
on **Cloudflare Pages**. No build step. It also owns the iOS universal-link
plumbing (AASA + `/pair` fallback) that used to live in the Rust API.

## Structure

- `public/` is the deployed site root (static assets). Root-relative links like `/styles.css` resolve here.
- `functions/api/contact.js` is the Pages Function (contact form to Resend), beside `public/` per the Pages layout.
- `wrangler.jsonc` is the Pages config (project name, `pages_build_output_dir`, `vars`). Run wrangler from this `web/` dir.
- `.dev.vars` holds local-only secrets for `wrangler pages dev` (gitignored).
- `DEPLOY.md` is the full deploy runbook.

## Files

| Path | Purpose |
|---|---|
| `public/index.html` | The landing page (single scroll). |
| `public/styles.css` / `public/main.js` | Styling + progressive enhancement (reveals, theme, form). |
| `public/pair/index.html` | Web fallback for `https://littlelove.dev/pair/<code>` when the app isn't installed. `noindex`. |
| `public/.well-known/apple-app-site-association` | AASA. Served as `application/json` via `_headers`. |
| `public/_headers` | Content-type for AASA, caching, security headers. |
| `public/_redirects` | `/pair/* → /pair/` (200 rewrite, URL preserved). |
| `functions/api/contact.js` | Pages Function: contact form → Resend email. |
| `public/robots.txt`, `public/sitemap.xml` | SEO. `/pair/` + `/api/` are disallowed. |
| `public/assets/og-image.png` | Social share card (1200×630). Regenerate from `og-image.svg`. |

## Local preview

```sh
# Full (site + contact Function), preferred. Needs wrangler + a key in web/.dev.vars:
cd web && wrangler pages dev          # http://localhost:8788

# Static only (no Function):
cd web/public && python3 -m http.server 8788
```

## Deploy

See **[DEPLOY.md](DEPLOY.md)** for the full runbook (install, local test, project
create, secret, deploy, Resend verification, custom domain, edge rate limit). In
short: `cd web && wrangler pages deploy`. For dashboard git-integration instead,
set build command _(none)_, **build output `web/public`**, root = repo root.

### Environment variables

| Var | Where | Notes |
|---|---|---|
| `RESEND_API_KEY` | secret (`wrangler pages secret put`) | From Resend. Never committed. |
| `CONTACT_TO` | `wrangler.jsonc` `vars` | Default `privacy@littlelove.dev` (routed to Gmail via Cloudflare Email Routing). |
| `CONTACT_FROM` | `wrangler.jsonc` `vars` | A Resend-verified sender on `littlelove.dev`. Default `LittleLove <noreply@littlelove.dev>`. |

The edge rate limit for `/api/contact` lives in `infra/cloudflare/ratelimit.tf`
(see DEPLOY.md step 7).

## The hero demo

The box beside the hero copy encrypts whatever the visitor types with real
AES-GCM (WebCrypto, one non-extractable key per channel tab, made on page load,
so switching channels changes the ciphertext the way each channel's own key does
in the app) and shows the
base64 output under "What we see". Nothing leaves the page. The app
itself uses XChaCha20-Poly1305; the demo uses what browsers ship. Until the
visitor touches it, it moves through the channel tabs and types a line in each.

The channel list in the Channels section is an illustration; `main.js` bumps
the oldest channel to the top every few seconds (FLIP slide), the way the app
sorts channels by latest activity. Channel names are not end-to-end encrypted
(the server stores them), so page copy says what's *in* a channel is
encrypted, never the channel itself; the privacy policy says the same. With JS
off, the box shows a static sample.

## Motion

All motion lives in the "motion" block at the end of `public/styles.css`. Every
animation shows something true about the product (the demo typing, the map's
messages flowing, the guarantee's words struck out). Not-yet-seen states are
hidden only under `html.js` (set by `main.js`), so the page reads with JS off,
and `prefers-reduced-motion` gets the finished state with nothing moving.

## Fonts

Self-hosted (no third-party requests), in keeping with the "no third parties"
voice. One family, Newsreader (variable: weight + optical size, roman and
italic), latin + latin-ext subsets in `public/assets/fonts/`; `@font-face`
declarations are in `public/fonts.css`. Monospace is the system's
(`ui-monospace`), used only for ciphertext and code. To change it, re-pull from
the Google Fonts CSS and
re-localize, or add the new woff2 + a `@font-face` block by hand.

## Launch polish (not blocking)

- When there's a public TestFlight link, the alpha CTA can point straight at it
  (today it routes to the request-access form, which fits the internal alpha).
