//! R2 presigned-URL minting. Presigning is offline SigV4 — no network call to
//! R2 — so this is safe to unit-test with dummy credentials. R2 requires
//! PATH-style URLs (`<account>.r2.cloudflarestorage.com/<bucket>/<key>`); using
//! virtual-host style is the most common R2 presigning mistake.
use std::time::Duration;

use rusty_s3::{actions::S3Action, Bucket, Credentials, UrlStyle};

use crate::config::R2Config;

#[derive(Clone)]
pub struct R2Presigner {
    bucket: Bucket,
    creds: Credentials,
}

impl R2Presigner {
    pub fn new(cfg: &R2Config) -> anyhow::Result<Self> {
        let endpoint = format!("https://{}.r2.cloudflarestorage.com", cfg.account_id)
            .parse()
            .map_err(|e| anyhow::anyhow!("bad R2 endpoint: {e}"))?;
        // R2 ignores the region but SigV4 requires one; "auto" is conventional.
        let bucket = Bucket::new(endpoint, UrlStyle::Path, cfg.bucket.clone(), "auto".to_string())
            .map_err(|e| anyhow::anyhow!("bad R2 bucket: {e}"))?;
        let creds = Credentials::new(cfg.access_key_id.clone(), cfg.secret_access_key.clone());
        Ok(Self { bucket, creds })
    }

    pub fn presign_put(&self, blob_key: &str, ttl: Duration) -> String {
        self.bucket
            .put_object(Some(&self.creds), blob_key)
            .sign(ttl)
            .to_string()
    }

    pub fn presign_get(&self, blob_key: &str, ttl: Duration) -> String {
        self.bucket
            .get_object(Some(&self.creds), blob_key)
            .sign(ttl)
            .to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn presigner() -> R2Presigner {
        R2Presigner::new(&R2Config {
            account_id: "acct123".into(),
            bucket: "littlelove-media".into(),
            access_key_id: "AKIDEXAMPLE".into(),
            secret_access_key: "secretexample".into(),
        })
        .unwrap()
    }

    #[test]
    fn put_url_is_path_style_signed() {
        let url = presigner().presign_put("01JBLOB", Duration::from_secs(600));
        assert!(url.contains("acct123.r2.cloudflarestorage.com"), "{url}");
        assert!(url.contains("/littlelove-media/01JBLOB"), "path-style: {url}");
        assert!(url.contains("X-Amz-Signature="), "{url}");
        assert!(url.contains("X-Amz-Expires=600"), "{url}");
    }

    #[test]
    fn get_url_is_signed() {
        let url = presigner().presign_get("01JBLOB", Duration::from_secs(600));
        assert!(url.contains("/littlelove-media/01JBLOB"), "{url}");
        assert!(url.contains("X-Amz-Signature="), "{url}");
    }
}
