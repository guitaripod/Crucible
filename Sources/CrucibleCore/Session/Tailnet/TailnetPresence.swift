import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether Tailscale is carrying traffic on this device. A tailnet address is a 100.64.0.0/10
/// (CGNAT) address on Tailscale's tunnel interface (`utun` on Apple platforms, `tailscale0` on
/// Linux), and nothing is there unless the VPN is up. Another app's sandbox hides everything else
/// about Tailscale from this one, so this is the only fact available.
package enum TailnetPresence {
    package static let appURL = URL(string: "tailscale://")!
    package static let appStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    package static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let name = String(validatingCString: interface.ifa_name), isTunnelInterface(name),
                  let host = numericHost(of: address), isTailnetAddress(host)
            else { continue }
            return host
        }
        return nil
    }

    package static var isConnected: Bool { localAddress() != nil }

    /// True for a literal IPv4 address inside 100.64.0.0/10.
    package static func isTailnetAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Whether an interface of this name is where Tailscale puts its address on this platform.
    package static func isTunnelInterface(_ name: String) -> Bool {
        #if canImport(Darwin)
        return name.hasPrefix("utun")
        #else
        return name.hasPrefix("tailscale")
        #endif
    }

    private static func numericHost(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        #if canImport(Darwin)
        let length = socklen_t(address.pointee.sa_len)
        #else
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? String(validatingCString: buffer) : nil
    }
}
