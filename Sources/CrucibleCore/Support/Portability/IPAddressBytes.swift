#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The bytes of a numeric IPv4 or IPv6 address, parsed with `inet_pton` so the same code runs where Network.framework
/// does not exist.
package enum IPAddressBytes {
    package static func v4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    package static func v6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}
