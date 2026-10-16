import Foundation

/// A Plex server to look for on the tailnet: who it is (machine identifier, friendly name) and
/// what its known routes say about where it listens.
package struct TailnetTarget: Sendable, Equatable {
    package let id: String
    package let name: String
    package let ports: [Int]
    package let plexDirectHash: String?

    private static let maxPorts = 3

    package init(id: String, name: String, knownURLs: [URL]) {
        self.id = id
        self.name = name
        ports = Self.ports(from: knownURLs)
        plexDirectHash = knownURLs.lazy.compactMap { Self.plexDirectHash(of: $0) }.first
    }

    package init(choice: ServerChoice) {
        self.init(id: choice.id, name: choice.name, knownURLs: choice.routes.compactMap { URL(string: $0.uri) })
    }

    package init(connection: PlexConnection) {
        self.init(id: connection.machineIdentifier, name: connection.serverName, knownURLs: connection.candidateURIs)
    }

    /// The default port first, then any other port a direct (non-relay) route uses, so a server
    /// published on 32401 behind Docker is still found.
    private static func ports(from urls: [URL]) -> [Int] {
        var ports = [ConnectionRoute.defaultPort]
        for url in urls where ConnectionRoute.kind(of: url) != .relay {
            if let port = url.port, !ports.contains(port) { ports.append(port) }
        }
        return Array(ports.prefix(maxPorts))
    }

    /// The `<hash>` in `<dashed-ip>.<hash>.plex.direct`: the same for every address of one server,
    /// which is what lets a certificate-valid HTTPS name be built for an address plex.tv never listed.
    private static func plexDirectHash(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), ConnectionRoute.isPlexDirect(host) else { return nil }
        let labels = host.split(separator: ".")
        return labels.count == 4 ? String(labels[1]) : nil
    }

    package func plexDirectURL(address: String, port: Int) -> URL? {
        guard let plexDirectHash else { return nil }
        return URL(string: "https://\(address.replacingOccurrences(of: ".", with: "-")).\(plexDirectHash).plex.direct:\(port)")
    }
}
