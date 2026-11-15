import Foundation

/// Plex's GDM, which finds Plex Media Servers on the local network without plex.tv: a client sends `M-SEARCH * HTTP/1.0`
/// to the multicast group 239.0.0.250 on UDP 32414, and every server answers with HTTP-style headers naming itself, its
/// machine identifier and its port. A platform that can send UDP installs a finder; discovery merges what it hears.
package enum PlexGDM {
    package static let group = "239.0.0.250"
    package static let port: UInt16 = 32414
    package static let message = "M-SEARCH * HTTP/1.0"

    /// A server that answered on the local network.
    package struct Server: Equatable, Hashable, Sendable {
        package let id: String
        package let name: String
        package let url: URL
    }

    /// The server in an answer from `host`, or nil when it is not a Plex Media Server's answer.
    package static func parse(_ answer: String, host: String) -> Server? {
        let lines = answer.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let status = lines.first, status.contains("200 OK") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["content-type"] == "plex/media-server", let id = headers["resource-identifier"], !id.isEmpty else { return nil }
        let port = headers["port"].flatMap(Int.init) ?? 32400
        let address = host.contains(":") ? "[\(host)]" : host
        guard (1...65535).contains(port), let url = URL(string: "http://\(address):\(port)") else { return nil }
        return Server(id: id, name: headers["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host, url: url)
    }

    private static let installed = OSAllocatedUnfairLock<(@Sendable () async -> [Server])?>(initialState: nil)

    /// Installs how this platform asks the local network; without one, discovery hears nothing locally.
    package static func install(_ finder: @escaping @Sendable () async -> [Server]) {
        installed.withLock { $0 = finder }
    }

    /// The servers on the local network, as the installed finder hears them.
    package static func find() async -> [Server] {
        guard let finder = installed.withLock({ $0 }) else { return [] }
        return await finder()
    }
}
