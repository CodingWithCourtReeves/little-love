# littlelove.dev marketing site

Static site (plain HTML/CSS/JS) for the apex domain **`littlelove.dev`**, hosted
on **Cloudflare Pages**. No build step. It also owns the iOS universal-link
plumbing (AASA + `/pair` fallback) that used to live in the Rust API.

## Files

| Path | Purpose |
|---|---|
| `index.html` | The landing page (single scroll). |
| `styles.css` / `main.js` | Styling + progressive enhancement (reveals, theme, form). |
| `pair/index.html` | Web fallback for `https://littlelove.dev/pair/<code>` when the app isn't installed. `noindex`. |
| `.well-known/apple-app-site-association` | AASA. Served as `application/json` via `_headers`. |
| `_headers` | Content-type for AASA, caching, security headers. |
| `_redirects` | `/pair/* → /pair/` (200 rewrite, URL preserved). |
| `functions/api/contact.js` | Pages Function: contact form → Resend email. |
| `robots.txt`, `sitemap.xml` | SEO. `/pair/` + `/api/` are disallowed. |
| `assets/og-image.png` | Social share card (1200×630). Regenerate from `og-image.svg`. |

## Local preview

```sh
# Static only (no contact form):
cd web && python3 -m http.server 8788
# Full (form + functions), needs wrangler:
npx wrangler pages dev web
```

## Deploy (Cloudflare Pages)

Connect the repo in the Cloudflare dashboard (or `npx wrangler pages deploy web`):

- **Build command:** _(none)_
- **Build output directory:** `web`
- **Root directory:** repo root

### Environment variables (Pages → Settings → Variables)

| Var | Notes |
|---|---|
| `RESEND_API_KEY` | **Secret.** From the Resend dashboard. |
| `CONTACT_TO` | Where notes land. Default `privacy@littlelove.dev` (routed to Court's Gmail via Cloudflare Email Routing). |
| `CONTACT_FROM` | A Resend-verified sender on `littlelove.dev`. Default `LittleLove <noreply@littlelove.dev>`. |

### DNS

Apex `littlelove.dev` → Cloudflare Pages (see `infra/cloudflare/dns.tf`).
`api.littlelove.dev` is unrelated and stays gray-cloud DNS-only.

### Rate-limit the contact endpoint (required before/at launch)

`POST /api/contact` is public and sends mail via Resend, so it must be rate
limited at the edge or it can be abused to burn the Resend quota. Add a
Cloudflare rate-limiting rule on the path `/api/contact` (e.g. ~5 requests per
minute per IP, action: block). The function also rejects requests whose `Origin`
isn't `littlelove.dev`, but that is defense-in-depth, not a substitute for the
edge rule.

## Dropping in real app GIFs

The two phones in the "Every way to be together" section are CSS-rendered mocks
(placeholders). To use a real screen recording, replace the contents of the
matching `.phone__screen[data-gif-slot="…"]` with:

```html
<img src="/assets/app/conversation.gif" alt="A LittleLove conversation" loading="lazy" />
```

Record at the phone's aspect ratio (~9:19), keep files small (optimize the GIF
or use a looping `<video>` with `muted autoplay playsinline`).

## Launch polish (not blocking)

- Self-host the fonts (Fraunces / Hanken Grotesk / Space Mono) to drop the
  Google Fonts request, consistent with the "no third parties" voice.
- Replace the placeholder TestFlight URL with the real public invite link.
