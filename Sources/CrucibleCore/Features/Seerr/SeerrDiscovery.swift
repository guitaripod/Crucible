import Foundation
import MidgarCore

/// Finds the viewer's Seerr: what they type, made into addresses worth trying, and the places Seerr usually runs next to a
/// Plex server.
package enum SeerrDiscovery {
    package static let defaultPort = 5055

    /// The addresses `typed` could mean, most likely first: as written, and with Seerr's port when none is given.
    package static func addresses(from typed: String) -> [URL] {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let hasScheme = text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://")
        if !hasScheme { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return [] }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v1", "/login", "/settings", "/requests"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components.path = path
        guard let asWritten = components.url else { return [] }
        guard components.port == nil, !hasScheme || components.scheme == "http" else { return [asWritten] }
        components.port = defaultPort
        guard let withPort = components.url else { return [asWritten] }
        if hasScheme { return [asWritten, withPort] }
        var secure = components
        secure.scheme = "https"
        secure.port = nil
        guard let secureURL = secure.url else { return [withPort, asWritten] }
        return localHost(of: asWritten) != nil ? [withPort, asWritten, secureURL] : [secureURL, withPort, asWritten]
    }

    /// Where Seerr may run next to the Plex server: Seerr's port on each host the server answers at on the home network.
    package static func candidates(serverRoutes: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for route in serverRoutes {
            guard let host = localHost(of: route), seen.insert(host).inserted else { continue }
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = defaultPort
            if let url = components.url { result.append(url) }
        }
        return result
    }

    /// The host of a route on the home network: a private address as is, or the address a `plex.direct` name spells out.
    /// Relay and public routes are left out, since nothing on them would answer for Seerr.
    static func localHost(of route: URL) -> String? {
        guard let host = route.host?.lowercased() else { return nil }
        if host.hasSuffix(".plex.direct") {
            let label = host.split(separator: ".").first.map(String.init) ?? ""
            let address = label.replacingOccurrences(of: "-", with: ".")
            return isPrivate(address) ? address : nil
        }
        if isPrivate(host) || host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return host }
        return nil
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, let second): return (16...31).contains(second)
        case (100, let second): return (64...127).contains(second)
        default: return false
        }
    }

    /// The first of `addresses` that answers as a Seerr for Plex, tried together; nil when none does.
    package static func firstSeerr(among addresses: [URL], client: SeerrClient = .shared) async -> (URL, SeerrPublicSettings)? {
        guard !addresses.isEmpty else { return nil }
        let found = await withTaskGroup(of: (Int, URL, SeerrPublicSettings)?.self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    guard let settings = try? await client.probe(address) else { return nil }
                    return (index, address, settings)
                }
            }
            var hits: [(Int, URL, SeerrPublicSettings)] = []
            for await hit in group { if let hit { hits.append(hit) } }
            return hits.min { $0.0 < $1.0 }
        }
        if let found { MidgarLog.notice("Seerr found at candidate \(found.0 + 1) of \(addresses.count)", category: .seerr) }
        return found.map { ($0.1, $0.2) }
    }

    /// The first address `typed` could mean that answers, or the reason none did.
    package static func resolve(typed: String, client: SeerrClient = .shared) async -> Result<(URL, SeerrPublicSettings), SeerrError> {
        let addresses = addresses(from: typed)
        guard !addresses.isEmpty else { return .failure(.unreachable) }
        var lastError = SeerrError.unreachable
        for address in addresses {
            do {
                return .success((address, try await client.probe(address)))
            } catch let error as SeerrError {
                if error == .notPlex { return .failure(.notPlex) }
                if error == .notSeerr { lastError = .notSeerr }
            } catch {
                continue
            }
        }
        return .failure(lastError)
    }

    /// The address as a viewer reads it: host and port, and the path when Seerr sits under one.
    package static func displayAddress(_ url: URL) -> String {
        var text = url.host ?? url.absoluteString
        if let port = url.port { text += ":\(port)" }
        let path = url.path
        if !path.isEmpty, path != "/" { text += path }
        return text
    }
}
