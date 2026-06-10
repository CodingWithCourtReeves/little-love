variable "zone_name" {
  type        = string
  description = "Cloudflare zone (apex domain)."
  default     = "littlelove.dev"
}

variable "account_id" {
  type        = string
  description = "Cloudflare account ID. Find it in the Cloudflare dashboard sidebar → Account Home → Account ID."
}

variable "railway_cname_target" {
  type        = string
  description = "CNAME target Railway prints when you attach `api.littlelove.dev` to the `littlelove-api` service (e.g. `xyz123.up.railway.app`)."
}

variable "forward_to_gmail" {
  type        = string
  description = "Destination Gmail address for `hello@` and `court@` aliases."
  default     = "codingwithcourt@gmail.com"
}
