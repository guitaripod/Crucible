import Foundation

/// The last server address the person typed, offered again as the prefill of the address field.
package enum RememberedServerAddress {
    private static let key = "last_server_ip"

    package static var text: String? {
        UserDefaults.standard.string(forKey: key)
    }

    package static func remember(_ address: ServerAddress, in defaults: UserDefaults = .standard) {
        defaults.set(displayText(for: address), forKey: key)
    }

    /// The bare host on the default port, `host:port` otherwise.
    static func displayText(for address: ServerAddress) -> String {
        address.port == ServerAddress.defaultPort ? address.host : "\(address.host):\(address.port)"
    }
}
