// Edge rate limiting for the marketing site's public contact endpoint.
//
// `POST https://littlelove.dev/api/contact` is an unauthenticated Cloudflare
// Pages Function that sends mail via Resend. Without a limit it can be hammered
// to burn the Resend quota / relay spam (see web/functions/api/contact.js and
// the review note in web/README.md). This caps it at 5 POSTs per minute per IP
// and blocks (HTTP 429) for a minute past that. The function also rejects
// non-littlelove.dev Origins, but that is defense-in-depth, not the real limit.
//
// NOTE on token scope: managing rate-limiting rulesets needs the zone **WAF**
// (Dynamic Rules / Rate Limiting) permission, which is broader than the
// Zone:Read + DNS:Edit + Zone Settings:Edit + Email Routing:Edit scope noted in
// main.tf. If `terraform apply` fails here with a permissions error (code
// 10000 / authentication), add "Zone > WAF > Edit" to the API token (or create
// this one rule in the dashboard) and re-apply.
resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "littlelove rate limiting"
  description = "Rate limits for littlelove.dev"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    ref         = "ratelimit_contact"
    description = "Throttle the public contact endpoint to curb abuse of the Resend mailer"
    expression  = "(http.request.uri.path eq \"/api/contact\" and http.request.method eq \"POST\")"
    action      = "block" // rate-limit block returns HTTP 429 by default

    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = 5
      mitigation_timeout  = 60
    }
  }
}
