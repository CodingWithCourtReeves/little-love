# R2 bucket for end-to-end-encrypted attachment blobs. The server brokers
# short-lived presigned PUT/GET URLs; it never sees blob contents or the
# per-file content key. No CORS config is needed — the iOS client uses native
# HTTP, not a browser origin.
resource "cloudflare_r2_bucket" "media" {
  account_id = var.account_id
  name       = "littlelove-media"
  location   = "ENAM" # eastern North America; match the user base
}
