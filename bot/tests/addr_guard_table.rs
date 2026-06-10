use std::net::IpAddr;

use littlelove_bot::addr_guard::is_private_ip;

#[test]
fn loopback_ipv4_allowed() {
    assert!(is_private_ip(&"127.0.0.1".parse().unwrap()));
}

#[test]
fn rfc1918_ranges_allowed() {
    for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
        let p: IpAddr = ip.parse().unwrap();
        assert!(is_private_ip(&p), "{ip}");
    }
}

#[test]
fn loopback_ipv6_allowed() {
    assert!(is_private_ip(&"::1".parse().unwrap()));
}

#[test]
fn link_local_allowed() {
    assert!(is_private_ip(&"169.254.0.5".parse().unwrap()));
    assert!(is_private_ip(&"fe80::1".parse().unwrap()));
}

#[test]
fn unique_local_v6_allowed() {
    assert!(is_private_ip(&"fc00::1".parse().unwrap()));
    assert!(is_private_ip(&"fd00::1".parse().unwrap()));
}

#[test]
fn public_ips_rejected() {
    for ip in ["1.1.1.1", "8.8.8.8", "2606:4700::1111"] {
        let p: IpAddr = ip.parse().unwrap();
        assert!(!is_private_ip(&p), "{ip}");
    }
}
