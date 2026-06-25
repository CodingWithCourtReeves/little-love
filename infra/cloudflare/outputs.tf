output "api_hostname" {
  value       = cloudflare_record.api.hostname
  description = "The fully-qualified API hostname (paste into client + docs)."
}

output "email_routing_enabled" {
  value       = cloudflare_email_routing_settings.main.enabled
  description = "Whether Cloudflare Email Routing is on for this zone."
}

output "forwarded_addresses" {
  value = [
    "privacy@${var.zone_name}",
    "alerts@${var.zone_name}",
  ]
  description = "Inbox aliases that forward to forward_to_gmail."
}
