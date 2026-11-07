//! Who may reach the server at all: this machine, the home network and the owner's tailnet. Everything else is
//! refused before any route runs.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Where a connection comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Peer {
    Loopback,
    Tailnet,
    Lan,
    Outside,
}

pub fn classify(ip: IpAddr) -> Peer {
    match ip.to_canonical() {
        IpAddr::V4(v4) => classify_v4(v4),
        IpAddr::V6(v6) => classify_v6(v6),
    }
}

fn classify_v4(ip: Ipv4Addr) -> Peer {
    let [first, second, _, _] = ip.octets();
    if ip.is_loopback() {
        Peer::Loopback
    } else if first == 100 && second & 0b1100_0000 == 0b0100_0000 {
        Peer::Tailnet
    } else if ip.is_private() || ip.is_link_local() {
        Peer::Lan
    } else {
        Peer::Outside
    }
}

fn classify_v6(ip: Ipv6Addr) -> Peer {
    let segments = ip.segments();
    if ip.is_loopback() {
        Peer::Loopback
    } else if segments[..3] == [0xfd7a, 0x115c, 0xa1e0] {
        Peer::Tailnet
    } else if segments[0] & 0xfe00 == 0xfc00 || segments[0] & 0xffc0 == 0xfe80 {
        Peer::Lan
    } else {
        Peer::Outside
    }
}

/// Addresses the QR code carries at most, so it stays small enough to scan from across a room.
const QR_ADDRESSES: usize = 4;

/// The addresses a device on the home network or the tailnet can reach this machine at, for the QR code: home
/// network IPv4 first, then the tailnet, IPv6 only when there is no IPv4, never link-local or a virtual machine's
/// bridge.
pub fn reachable_addresses() -> Vec<IpAddr> {
    let interfaces: Vec<(String, IpAddr)> =
        if_addrs::get_if_addrs().unwrap_or_default().into_iter().map(|interface| (interface.name.clone(), interface.ip())).collect();
    choose_addresses(&interfaces)
}

pub fn choose_addresses(interfaces: &[(String, IpAddr)]) -> Vec<IpAddr> {
    let virtual_bridge =
        |name: &str| ["bridge", "vmnet", "virbr", "docker", "br-", "veth", "utun", "llw", "awdl"].iter().any(|prefix| name.starts_with(prefix));
    let mut found: Vec<IpAddr> = interfaces
        .iter()
        .filter(|(name, ip)| classify(*ip) == Peer::Tailnet || !virtual_bridge(name))
        .map(|(_, ip)| *ip)
        .filter(|ip| matches!(classify(*ip), Peer::Lan | Peer::Tailnet))
        .filter(|ip| match ip {
            IpAddr::V4(v4) => !v4.is_link_local(),
            IpAddr::V6(v6) => v6.segments()[0] & 0xffc0 != 0xfe80,
        })
        .collect();
    let has_v4 = found.iter().any(IpAddr::is_ipv4);
    found.retain(|ip| ip.is_ipv4() || !has_v4);
    found.sort_by_key(|ip| (classify(*ip) == Peer::Tailnet, ip.is_ipv6(), *ip));
    found.dedup();
    found.truncate(QR_ADDRESSES);
    found
}

/// `host:port`, bracketing IPv6.
pub fn host_port(ip: IpAddr, port: u16) -> String {
    match ip {
        IpAddr::V4(v4) => format!("{v4}:{port}"),
        IpAddr::V6(v6) => format!("[{v6}]:{port}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(text: &str) -> Peer {
        classify(text.parse().unwrap())
    }

    #[test]
    fn sorts_peers_into_where_they_come_from() {
        assert_eq!(peer("127.0.0.1"), Peer::Loopback);
        assert_eq!(peer("::1"), Peer::Loopback);
        assert_eq!(peer("100.101.102.103"), Peer::Tailnet);
        assert_eq!(peer("fd7a:115c:a1e0::1"), Peer::Tailnet);
        assert_eq!(peer("192.168.1.20"), Peer::Lan);
        assert_eq!(peer("10.0.0.2"), Peer::Lan);
        assert_eq!(peer("172.20.0.5"), Peer::Lan);
        assert_eq!(peer("fd00::5"), Peer::Lan);
        assert_eq!(peer("::ffff:192.168.1.20"), Peer::Lan);
        assert_eq!(peer("100.63.0.1"), Peer::Outside);
        assert_eq!(peer("8.8.8.8"), Peer::Outside);
        assert_eq!(peer("2001:db8::1"), Peer::Outside);
    }

    #[test]
    fn the_qr_code_carries_the_home_network_then_the_tailnet() {
        let interface = |name: &str, ip: &str| (name.to_string(), ip.parse().unwrap());
        let chosen = choose_addresses(&[
            interface("en0", "169.254.58.101"),
            interface("en0", "192.168.1.58"),
            interface("bridge100", "192.168.64.1"),
            interface("utun4", "100.127.250.64"),
            interface("en0", "fd5b:8e52::1"),
            interface("lo0", "127.0.0.1"),
        ]);
        assert_eq!(chosen, vec!["192.168.1.58".parse::<IpAddr>().unwrap(), "100.127.250.64".parse().unwrap()]);
        assert_eq!(choose_addresses(&[interface("en0", "fd5b:8e52::1")]), vec!["fd5b:8e52::1".parse::<IpAddr>().unwrap()]);
    }

    #[test]
    fn brackets_ipv6_hosts() {
        assert_eq!(host_port("192.168.1.2".parse().unwrap(), 32500), "192.168.1.2:32500");
        assert_eq!(host_port("fd00::1".parse().unwrap(), 32500), "[fd00::1]:32500");
    }
}
