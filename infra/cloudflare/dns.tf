// The LittleLove API endpoint. DO NOT proxy through Cloudflare (orange cloud) —
// it would terminate TLS at Cloudflare's edge and give them visibility into the
// otherwise-E2EE WSS traffic, breaking the founder positioning. Railway issues
// its own Let's Encrypt cert; gray cloud lets that work end-to-end.
resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.main.id
  name    = "api"
  content = var.railway_cname_target
  type    = "CNAME"
  proxied = false
  ttl     = 1 // 1 = Auto (300s) for non-proxied records
  comment = "LittleLove API → Railway. Gray cloud required (see comment in dns.tf)."
}
