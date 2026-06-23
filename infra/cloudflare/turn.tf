// Cloudflare TURN (Realtime) key — voice calling NAT traversal.
//
// NOT MANAGED BY TERRAFORM. The pinned cloudflare provider (~> 4.50) exposes no
// TURN/Realtime resource (verified: `tofu providers schema -json | jq ... | grep
// -i turn` returns nothing), and bumping to the v5 provider purely for this would
// force a breaking migration across every DNS/email/R2 resource here. So the TURN
// key is provisioned out-of-band and stored as a secret — the same treatment as
// the R2 S3 access keys (see README "Not the same as the app's R2 credentials").
//
// A TURN key is a long-lived server-side secret that mints unlimited short-lived
// per-call ICE credentials. Create one DEV key and one PROD key so dev traffic
// never touches prod metering. Keep the secret server-side (never ship it to the
// app — the app receives only short-lived credentials over the authenticated WS).
//
// ── Create via dashboard (simplest) ───────────────────────────────────────────
//   Cloudflare dashboard → (this account) → Realtime → TURN → Create.
//   Copy the Key ID (`uid`) and the API Token (`key`).
//
// ── Or create via API ─────────────────────────────────────────────────────────
//   Requires a token with the account-scoped "Calls" (Realtime) Write permission
//   — the existing DNS/Email/R2 Terraform token does NOT have it.
//
//   curl https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/calls/turn_keys \
//     -H 'Content-Type: application/json' \
//     -H "Authorization: Bearer $CF_CALLS_TOKEN" \
//     -d '{"name":"littlelove-dev"}'
//
//   Response → `result.uid` (= TURN_KEY_ID) and `result.key` (= TURN_API_TOKEN).
//
// ── Where the values go ───────────────────────────────────────────────────────
//   dev   → .secrets.env  (TURN_KEY_ID / TURN_API_TOKEN; sourced by dev-phones.sh)
//   prod  → Railway service env vars on `littlelove-api` (same two names)
//
// The API server (server/src/turn.rs) calls
//   POST https://rtc.live.cloudflare.com/v1/turn/keys/$TURN_KEY_ID/credentials/generate-ice-servers
//   Authorization: Bearer $TURN_API_TOKEN
// to mint the per-call ICE servers it returns to clients.
