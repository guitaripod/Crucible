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

/// Where a model server is, judged from its address alone: on this machine or one of the owner's networks, or
/// outside them at the named host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModelPlace {
    Own,
    Outside(String),
}

/// Endings of names that never leave a home network or a tailnet: mDNS, a router's own domain and MagicDNS.
const OWN_SUFFIXES: &[&str] = &[".local", ".localhost", ".lan", ".home", ".internal", ".home.arpa", ".ts.net"];

/// Where the model server at `url` is. An address is read as what it is; a name counts as the owner's when it has
/// no dot or ends in a suffix only a private network resolves, and anything unreadable counts as outside.
pub fn model_place(url: &str) -> ModelPlace {
    let Some(host) = reqwest::Url::parse(url).ok().and_then(|parsed| parsed.host_str().map(str::to_lowercase)) else {
        return ModelPlace::Outside(url.to_string());
    };
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let own = match bare.parse::<IpAddr>() {
        Ok(ip) => classify(ip) != Peer::Outside,
        Err(_) => bare == "localhost" || !bare.contains('.') || OWN_SUFFIXES.iter().any(|suffix| bare.ends_with(suffix)),
    };
    if own {
        ModelPlace::Own
    } else {
        ModelPlace::Outside(bare.to_string())
    }
}

/// Whether a key may travel to `url`: over HTTPS anywhere, over plain HTTP only inside the owner's own networks.
pub fn carries_a_key(url: &str) -> bool {
    url.trim_start().to_lowercase().starts_with("https://") || model_place(url) == ModelPlace::Own
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
    fn tells_a_model_on_the_owners_networks_from_one_outside() {
        for own in [
            "http://127.0.0.1:8081/v1",
            "http://localhost:11434/v1",
            "http://[::1]:1234/v1",
            "http://192.168.1.40:8081/v1",
            "http://100.101.102.103:8081/v1",
            "http://gamingpc:8081/v1",
            "http://nas.local:11434/v1",
            "https://arch.tail1234.ts.net/v1",
        ] {
            assert_eq!(model_place(own), ModelPlace::Own, "{own}");
        }
        assert_eq!(model_place("https://openrouter.ai/api/v1"), ModelPlace::Outside("openrouter.ai".into()));
        assert_eq!(model_place("https://API.OpenAI.com/v1"), ModelPlace::Outside("api.openai.com".into()));
        assert_eq!(model_place("http://8.8.8.8/v1"), ModelPlace::Outside("8.8.8.8".into()));
        assert_eq!(model_place("http://[2001:db8::1]/v1"), ModelPlace::Outside("2001:db8::1".into()));
        assert_eq!(model_place("not a url"), ModelPlace::Outside("not a url".into()));
    }

    #[test]
    fn a_key_leaves_the_owners_networks_only_over_https() {
        assert!(carries_a_key("https://openrouter.ai/api/v1"));
        assert!(carries_a_key("http://127.0.0.1:8081/v1"));
        assert!(carries_a_key("http://100.101.102.103:8081/v1"));
        assert!(!carries_a_key("http://openrouter.ai/api/v1"));
        assert!(!carries_a_key("http://8.8.8.8/v1"));
    }

    #[test]
    fn brackets_ipv6_hosts() {
        assert_eq!(host_port("192.168.1.2".parse().unwrap(), 32500), "192.168.1.2:32500");
        assert_eq!(host_port("fd00::1".parse().unwrap(), 32500), "[fd00::1]:32500");
    }
}
