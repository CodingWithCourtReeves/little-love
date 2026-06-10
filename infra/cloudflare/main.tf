// The provider reads CLOUDFLARE_API_TOKEN from the environment. Token scope:
//   Zone:Read + DNS:Edit + Zone Settings:Edit + Email Routing:Edit,
//   restricted to the littlelove.dev zone.
provider "cloudflare" {}

data "cloudflare_zone" "main" {
  name = var.zone_name
}
