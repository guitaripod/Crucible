import Foundation

/// One computer on the tailnet, as the Tailscale API lists it.
package struct TailscaleDevice: Sendable, Hashable, Decodable {
    package let name: String?
    package let hostname: String?
    package let addresses: [String]
    package let os: String?
    package let lastSeen: String?
    package let connectedToControl: Bool?

    package init(
        name: String? = nil,
        hostname: String? = nil,
        addresses: [String],
        os: String? = nil,
        lastSeen: String? = nil,
        connectedToControl: Bool? = nil
    ) {
        self.name = name
        self.hostname = hostname
        self.addresses = addresses
        self.os = os
        self.lastSeen = lastSeen
        self.connectedToControl = connectedToControl
    }

    private enum CodingKeys: String, CodingKey {
        case name, hostname, addresses, os, lastSeen, connectedToControl
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
        os = try container.decodeIfPresent(String.self, forKey: .os)
        lastSeen = try container.decodeIfPresent(String.self, forKey: .lastSeen)
        connectedToControl = try container.decodeIfPresent(Bool.self, forKey: .connectedToControl)
    }

    /// The device's IPv4 tailnet address, the one every probe uses: it needs no DNS and the IPv6
    /// address reaches the same machine.
    package var tailnetIPv4: String? {
        addresses.first { TailnetPresence.isTailnetAddress($0) }
    }

    /// Whether a Plex server could be running here and answering now. Phones, TVs and tablets never
    /// host one, and an offline peer swallows every probe into a full timeout.
    package func isWorthProbing(now: Date = Date()) -> Bool {
        if let os = os?.lowercased(), Self.clientOnlySystems.contains(os) { return false }
        if let connectedToControl { return connectedToControl }
        guard let seen = lastSeenDate else { return true }
        return seen > now.addingTimeInterval(-Self.recentlySeen)
    }

    private static let clientOnlySystems: Set<String> = ["ios", "ipados", "tvos", "watchos", "visionos", "android"]
    private static let recentlySeen: TimeInterval = 600

    private var lastSeenDate: Date? {
        guard let lastSeen else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: lastSeen) { return date }
        plain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: lastSeen)
    }
}

package enum TailscaleAPIError: Error, Equatable, Sendable {
    case tokenRejected
    case unavailable
}

package enum TailscaleAPI {
    private struct DevicesResponse: Decodable {
        let devices: [TailscaleDevice]
    }

    /// Lists the tailnet's devices with an API access token. Throws `tokenRejected` for a 401 or 403.
    package static func devices(token: String) async throws -> [TailscaleDevice] {
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices") else { throw TailscaleAPIError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TailscaleAPIError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw TailscaleAPIError.tokenRejected }
        guard status == 200, let decoded = try? JSONDecoder().decode(DevicesResponse.self, from: data) else {
            throw TailscaleAPIError.unavailable
        }
        return decoded.devices
    }
}
