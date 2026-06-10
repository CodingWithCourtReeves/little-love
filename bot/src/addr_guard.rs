//! Private-IP allow-list. The bot refuses to talk to a non-private LLM
//! endpoint by code — see spec §10 and positioning.md.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};

use thiserror::Error;
use url::Url;

#[derive(Debug, Error)]
pub enum AddrGuardError {
    #[error("invalid URL: {0}")]
    BadUrl(String),
    #[error("URL missing host")]
    NoHost,
    #[error("DNS resolution failed: {0}")]
    Resolve(String),
    #[error("endpoint {host} resolves to public IP {ip}; refusing — bot only talks to private addresses")]
    PublicAddress { host: String, ip: IpAddr },
}

pub fn is_private_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_private_v4(v4),
        IpAddr::V6(v6) => is_private_v6(v6),
    }
}

fn is_private_v4(v4: &Ipv4Addr) -> bool {
    if v4.is_loopback() || v4.is_link_local() || v4.is_private() {
        return true;
    }
    let octets = v4.octets();
    // 100.64.0.0/10 (CGNAT) — treat as private; benign for the bot.
    if octets[0] == 100 && (octets[1] & 0xC0) == 0x40 {
        return true;
    }
    false
}

fn is_private_v6(v6: &Ipv6Addr) -> bool {
    if v6.is_loopback() {
        return true;
    }
    let s = v6.segments()[0];
    // fe80::/10 link-local
    if (s & 0xFFC0) == 0xFE80 {
        return true;
    }
    // fc00::/7 unique-local
    if (s & 0xFE00) == 0xFC00 {
        return true;
    }
    false
}

pub fn ensure_url_is_private(url: &str) -> Result<(), AddrGuardError> {
    let parsed = Url::parse(url).map_err(|e| AddrGuardError::BadUrl(e.to_string()))?;
    let host = parsed.host_str().ok_or(AddrGuardError::NoHost)?.to_string();
    let port = parsed.port_or_known_default().unwrap_or(80);
    let addrs = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| AddrGuardError::Resolve(e.to_string()))?;
    for addr in addrs {
        if !is_private_ip(&addr.ip()) {
            return Err(AddrGuardError::PublicAddress {
                host,
                ip: addr.ip(),
            });
        }
    }
    Ok(())
}
