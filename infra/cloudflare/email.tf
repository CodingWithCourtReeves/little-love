// Cloudflare Email Routing — forwards inbound mail at hello@littlelove.dev and
// court@littlelove.dev to Court's Gmail. The required MX / TXT / SPF DNS
// records are managed by Cloudflare automatically once routing is enabled;
// they don't need to be declared here.
resource "cloudflare_email_routing_settings" "main" {
  zone_id = data.cloudflare_zone.main.id
  enabled = true
}

resource "cloudflare_email_routing_address" "gmail" {
  account_id = var.account_id
  email      = var.forward_to_gmail
}

resource "cloudflare_email_routing_rule" "hello" {
  zone_id = data.cloudflare_zone.main.id
  name    = "hello → gmail"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "hello@${var.zone_name}"
  }

  action {
    type  = "forward"
    value = [var.forward_to_gmail]
  }

  depends_on = [
    cloudflare_email_routing_settings.main,
    cloudflare_email_routing_address.gmail,
  ]
}

resource "cloudflare_email_routing_rule" "court" {
  zone_id = data.cloudflare_zone.main.id
  name    = "court → gmail"
  enabled = true

  matcher {
    type  = "literal"
    field = "to"
    value = "court@${var.zone_name}"
  }

  action {
    type  = "forward"
    value = [var.forward_to_gmail]
  }

  depends_on = [
    cloudflare_email_routing_settings.main,
    cloudflare_email_routing_address.gmail,
  ]
}
