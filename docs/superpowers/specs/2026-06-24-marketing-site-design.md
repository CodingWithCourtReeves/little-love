# LittleLove marketing site — design (2026-06-24)

The public marketing site for LittleLove, served at the apex **`littlelove.dev`**.
Goal: convert privacy-conscious and long-distance couples into TestFlight alpha
testers, with an honest, code-verifiable privacy story.

## Decisions

- **Stack: plain HTML / CSS / JS.** No framework, no build step. One landing
  page + one `/pair` fallback page + static SEO/AASA files + one serverless
  function. Astro was considered and rejected as overkill at this scale —
  revisit only if we add a content/blog section (the SEO FAQ play).
- **Host: Cloudflare Pages** (static). Free, global CDN, automatic TLS, deploy
  on push. No Docker, no nginx, no always-on service. Already aligned with our
  Cloudflare infra (DNS, R2, email, TURN).
- **Apex `littlelove.dev` ownership moves to this site.** It absorbs the two
  pairing responsibilities currently served by the Rust API:
  1. `/.well-known/apple-app-site-association` (AASA).
  2. `/pair/<code>` web fallback (shown only when the app isn't installed; the
     GET is inert — a real consume needs the app's Ed25519 signature).
  `api.littlelove.dev` is untouched (stays gray-cloud DNS-only).

## Voice & strategy (from audience research)

The open lane: no couples app leads with *true* E2EE; no privacy app is
couple-shaped. We own the intersection — the "quiet room for two" intimacy +
the genuine "not even we can read it" promise + two things competitors can't
copy: **built by an actual couple (no VC, no AI)** and **open code you can
verify**.

Research-driven guardrails:

- **Translate, don't lecture.** Lead with the plain-language outcome, footnote
  the term: *"Only the two of you can read your messages — not us, not Big
  Tech. (That's what 'end-to-end encrypted' means.)"* (>⅓ of people who value
  E2EE wrongly think the provider can still read it.)
- **No hollow boilerplate** — avoid "privacy-first," "military-grade," "your
  privacy matters." Back every claim with a concrete mechanism.
- **Concrete & sensory over saccharine** — "a voice note waiting at sunrise"
  beats "feel closer than ever." Avoid soulmate/two-halves clichés, virtual
  hugs, surveillance/tracking framing.
- **Metadata differentiator** (code-verified): *"We don't track who you talk to
  or when."*

## Honesty guardrails (from code fact-check — claims MUST stay true)

- ✅ Safe to say: E2EE on-device to partner's X25519 device key; server stores
  only ciphertext it has no key to read; built on X25519 + Ed25519 +
  HKDF-SHA256 + XChaCha20-Poly1305; content-free push; no analytics/trackers/
  ads/AI in app or message path; one partner per account, enforced server-side;
  photos/video, voice memos, voice + video calls all shipped and E2EE.
- ❌ Do NOT say: "no third parties — *ever*" (Apple APNs sees metadata; CF
  TURN/R2 handle ciphertext/creds; link previews fetched by sender's device) →
  use **"no third party in the message path."** No "Signal-grade" / forward
  secrecy / ratcheting (text uses a static room key). Not "a room is exactly
  two people" → **"one partner per account, enforced server-side."**

## Page structure (single scrolling page)

1. **Hero** — `# Just the two of you. No one else. Not even us.` + sub
   ("end-to-end encrypted messenger built for couples … and we can't read any
   of it") + **CTA: Join the alpha on TestFlight**. Animated hero SVG slot.
2. **The guarantee** — "Not even we can read it" in plain words + the mechanism;
   triplet negation **No ads. No trackers. No AI.** + metadata line.
3. **Close the distance** (LDR) — sensory, ritual-led: sunrise voice note across
   time zones, calls/video to share the everyday, channels = a room for two.
   Animated SVG slot (e.g. distance closing / sunrise).
4. **Everything's encrypted, not just text** — photos & video, voice memos,
   voice + video calls; all shipped, all E2EE; "same primitives as text, not
   bolted on." **App GIF slot(s)** here.
5. **Built by a couple** — founder-operated, no VC, no AI, hosted by us. The
   "what's the catch?" disarm.
6. **Don't trust us — read the code** — verification proof point, links the
   now-public repo. Animated SVG slot optional (code motif).
7. **CTA footer** — TestFlight + **Resend contact form** ("Questions? Drop us a
   line.").

### Media slots (explicit, per user request)

- **Animated SVG/vector slots** in hero, LDR, and (optional) read-the-code
  sections — inline SVG + CSS/SMIL, no JS framework. Lightweight, decorative,
  on-brand (lock/heart/channel/sunrise motifs).
- **App GIF slots** (≥2) — real screen recordings shown in a phone frame
  (conversation view, a call). Built as drop-in slots with placeholders;
  real GIFs to be recorded from the app and committed later.

## Look & feel

Mirror the app's adaptive **light/dark palette** (`mocks/palette-gallery.html`)
so the site feels like the product — calm, warm, intimate, not a loud SaaS
landing. Respect `prefers-color-scheme`. Build executed via the
`frontend-design` skill for design quality.

## SEO / metadata (hand-authored, no framework needed)

- `sitemap.xml` (canonical URL), `robots.txt` (allow crawl, point to sitemap,
  **disallow `/pair/`**).
- `/pair` fallback page carries `<meta name="robots" content="noindex">`.
- `<title>`, meta description, canonical, `lang`.
- Open Graph + Twitter Card tags + a designed `og:image` (link previews when a
  couple shares the URL).
- JSON-LD: `SoftwareApplication` / `Organization`.
- Favicon + apple-touch-icon.

## Contact form

`functions/api/contact` — a Cloudflare Pages Function that validates the POST and
calls the **Resend** API to email Court. Resend API key stored as a Pages env
secret (never committed). Honeypot + basic rate-limit for spam.

## Infra / repo changes

- **DNS:** add apex `littlelove.dev` → Cloudflare Pages in
  `infra/cloudflare/dns.tf` (Terraform). `api.` record unchanged.
- **AASA content-type:** Cloudflare Pages `_headers` rule forcing
  `Content-Type: application/json` on `/.well-known/apple-app-site-association`
  (exact match iOS requires). `/pair/* /pair 200` rewrite in `_redirects`.
- **Retire** `apple_app_site_association` + `pair_landing` from
  `server/src/well_known.rs` and their routes in `server/src/main.rs` once the
  apex serves them.
- **Repo → public** (git-history audit cleared it; no rotation/scrub needed).
  Optional: scrub the local-only `devsecret123` MinIO password for tidiness.
- **Refresh** `docs/positioning.md` (it lists shipped media/voice/video as
  "roadmap" — stale).

## Out of scope (now)

Blog/FAQ content section (would trigger an Astro migration), third-party
security audit, bug bounty, reproducible builds, App Store launch.

## Directory

`web/` at repo root. Built on worktree branch `worktree-marketing-site`.
