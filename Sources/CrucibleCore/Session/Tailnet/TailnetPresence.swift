import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether Tailscale is carrying traffic on this device. A tailnet address is a 100.64.0.0/10
/// (CGNAT) address on a `utun` interface, and nothing is there unless the VPN is up. Another app's
/// sandbox hides everything else about Tailscale from this one, so this is the only fact available.
package enum TailnetPresence {
    package static let appURL = URL(string: "tailscale://")!
    package static let appStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    package static func localAddress() -> String? {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let name = String(validatingCString: interface.ifa_name), name.hasPrefix("utun"),
                  let host = numericHost(of: address), isTailnetAddress(host)
            else { continue }
            return host
        }
        #endif
        return nil
    }

    package static var isConnected: Bool { localAddress() != nil }

    /// True for a literal IPv4 address inside 100.64.0.0/10.
    package static func isTailnetAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    #if canImport(Darwin)
    private static func numericHost(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? String(validatingCString: buffer) : nil
    }
    #endif
}
