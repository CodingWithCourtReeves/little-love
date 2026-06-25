// Cloudflare Email Routing — enables inbound mail forwarding for littlelove.dev
// and forwards `privacy@littlelove.dev` to Court's Gmail. The privacy@ alias
// is the externally-published contact for the project (privacy questions, data
// requests, abuse reports), matching the founder positioning.
//
// The destination address (codingwithcourt@gmail.com) is managed in the
// Cloudflare UI, not here — the API token used to apply this config is
// account-scoped but lacks the `Email Routing Addresses` permission, so the
// `cloudflare_email_routing_address` resource fails with code 10000.
// Adding/removing destination addresses is a low-frequency one-click op in the
// dashboard; declarative management isn't worth chasing the perm.
//
// The required MX / TXT / SPF DNS records are managed by Cloudflare
// automatically once routing is enabled; they don't need to be declared here.
resource "cloudflare_email_routing_settings" "main" {
  zone_id = data.cloudflare_zone.main.id
  enabled = true
}

resource "cloudflare_email_routing_rule" "privacy" {
  zone_id = data.cloudflare_zone.main.id
  name    = "privacy → gmail"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "privacy@${var.zone_name}"
  }

  action {
    type  = "forward"
    value = [var.forward_to_gmail]
  }

  depends_on = [cloudflare_email_routing_settings.main]
}

// `alerts@littlelove.dev` is the address our self-hosted error monitor (Bugsink)
// both sends from (via Resend) and notifies on a new issue. This rule forwards
// the inbound copy to Court's Gmail so crash alerts actually land somewhere a
// human reads. Same shape as the `privacy@` rule above. The from-side already
// works because littlelove.dev is a Resend-verified sending domain.
resource "cloudflare_email_routing_rule" "alerts" {
  zone_id = data.cloudflare_zone.main.id
  name    = "alerts → gmail"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "alerts@${var.zone_name}"
  }

  action {
    type  = "forward"
    value = [var.forward_to_gmail]
  }

  depends_on = [cloudflare_email_routing_settings.main]
}
