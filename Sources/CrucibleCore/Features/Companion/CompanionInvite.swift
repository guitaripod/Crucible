import CryptoKit
import Foundation
import Network

/// What pairing with Crucible Server needs: its name, where it may answer, the single-use secret its terminal showed,
/// and the certificate fingerprint when the QR code carried one.
package struct CompanionInvite: Equatable, Sendable {
    package let name: String
    package let hosts: [String]
    package let secret: Data
    package let fingerprint: String?

    package static let defaultPort = 32500

    package init(name: String, hosts: [String], secret: Data, fingerprint: String?) {
        self.name = name
        self.hosts = hosts
        self.secret = secret
        self.fingerprint = fingerprint
    }

    /// A `crucible://pair?v=1&name=…&hosts=…&secret=…&fp=…` link, as the QR code `crucible-server setup` shows carries it.
    package init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let encoded = value("secret"), let secret = Base32.decode(encoded), secret.count == 16 else { return nil }
        let hosts = (value("hosts") ?? "").split(separator: ",").map(String.init).filter { Self.isHost($0) && Self.isNearby($0) }
        guard !hosts.isEmpty else { return nil }
        let fingerprint = value("fp").map { $0.lowercased() }.flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        self.init(name: value("name") ?? "Crucible Server", hosts: hosts, secret: secret, fingerprint: fingerprint)
    }

    /// A code typed from the terminal (`KQ7M-2XRD-…`), tried at `hosts`; the server's proof stands in for a fingerprint.
    package init?(code: String, hosts: [String]) {
        let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let secret = Base32.decode(cleaned), secret.count == 16, !hosts.isEmpty else { return nil }
        self.init(name: "Crucible Server", hosts: hosts, secret: secret, fingerprint: nil)
    }

    /// The id both sides derive from the secret, so a request can name it without revealing it.
    package var secretID: String {
        var hasher = SHA256()
        hasher.update(data: Data("crucible-pair-id".utf8))
        hasher.update(data: secret)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The `crucible://pair` link for this invite, the inverse of `init?(url:)`: what a paired iPhone hands a nearby
    /// Apple TV.
    package var link: URL {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "secret", value: Base32.encode(secret)),
        ] + (fingerprint.map { [URLQueryItem(name: "fp", value: $0)] } ?? [])
        return components.url ?? URL(string: "\(DeepLink.scheme)://pair")!
    }

    /// A fresh single-use secret, made on this device and never sent anywhere but to a paired server.
    package static func newSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Whether a link's host is on the home network or a tailnet: a private, link-local, CGNAT or ULA address, a `.local`
    /// name, or a plex.direct name for a private address. A scanned or forged link can never send a pairing, and later
    /// the person's Plex token, to a computer on the internet. `tailnetNames` also admits MagicDNS names under `ts.net`,
    /// right for the address this device already reaches its own Plex server at but never for a link, since Funnel can
    /// put such a name on the internet.
    static func isNearby(_ hostPort: String, tailnetNames: Bool = false) -> Bool {
        var host = hostPort
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        host = host.lowercased()
        if host.hasSuffix(".local") || tailnetNames && host.hasSuffix(".ts.net") { return true }
        if host.hasSuffix(".plex.direct"), let label = host.split(separator: ".").first {
            host = label.replacingOccurrences(of: "-", with: ".")
        }
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 169 && b[1] == 254)
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        }
        return false
    }

    /// `host:port` or `[v6]:port`, nothing that could carry a path or credentials.
    static func isHost(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isLetter || $0.isNumber || ".:[]-".contains($0) }
    }
}

/// The two proofs of pairing: HMAC-SHA256 over a role, the certificate fingerprint and both nonces, each part prefixed
/// with its length, exactly as `crucible-server` computes them.
package enum CompanionProof {
    package static func server(secret: Data, fingerprint: String, deviceNonce: String, serverNonce: String) -> String {
        proof(secret: secret, role: "crucible-pair-server", fingerprint: fingerprint, deviceNonce: deviceNonce, serverNonce: serverNonce)
    }

    package static func device(secret: Data, fingerprint: String, deviceNonce: String, serverNonce: String) -> String {
        proof(secret: secret, role: "crucible-pair-device", fingerprint: fingerprint, deviceNonce: deviceNonce, serverNonce: serverNonce)
    }

    private static func proof(secret: Data, role: String, fingerprint: String, deviceNonce: String, serverNonce: String) -> String {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: secret))
        for part in [role, fingerprint, deviceNonce, serverNonce].map({ Data($0.utf8) }) {
            var length = UInt32(part.count).bigEndian
            mac.update(data: Data(bytes: &length, count: 4))
            mac.update(data: part)
        }
        return mac.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two proofs in time that does not depend on where they differ.
    package static func matches(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// RFC 4648 base32 without padding, the alphabet the server's codes use.
package enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    package static func encode(_ data: Data) -> String {
        var bits = 0, value = 0
        var text = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                text.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { text.append(alphabet[(value << (5 - bits)) & 31]) }
        return text
    }

    package static func decode(_ text: String) -> Data? {
        var bits = 0, value = 0
        var bytes = [UInt8]()
        for character in text.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return Data(bytes)
    }
}


/// An Apple TV asking to be added: the secret it made and shows as a QR code (`crucible://add-device?v=1&secret=…&name=…`),
/// which a paired iPhone scans and hands to the server, and the name it gives itself.
package struct CompanionDeviceInvite: Equatable, Sendable {
    package let name: String
    package let secret: Data
    package let expires: Date?

    package init(name: String, secret: Data, expires: Date? = nil) {
        self.name = name
        self.secret = secret
        self.expires = expires.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }

    /// Whether the Apple TV has stopped waiting for this code.
    package func isExpired(now: Date = Date()) -> Bool {
        expires.map { $0 <= now } ?? false
    }

    package init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "add-device",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let encoded = items.first(where: { $0.name == "secret" })?.value,
              let secret = Base32.decode(encoded), secret.count == 16 else { return nil }
        let name = items.first { $0.name == "name" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expires = items.first { $0.name == "exp" }?.value.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        self.init(name: name.isEmpty ? "Apple TV" : String(name.prefix(60)), secret: secret, expires: expires)
    }

    package var link: URL {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = "add-device"
        components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "secret", value: Base32.encode(secret)), URLQueryItem(name: "name", value: name)]
            + (expires.map { [URLQueryItem(name: "exp", value: String(Int($0.timeIntervalSince1970)))] } ?? [])
        return components.url ?? URL(string: "\(DeepLink.scheme)://add-device")!
    }
}

/// What an Apple TV and a nearby iPhone say over the link DeviceDiscoveryUI opens between them: the Apple TV names itself,
/// and the iPhone answers with a `crucible://pair` link for a secret it just handed the server, or with a refusal. One line
/// each, so neither side waits on the other's framing.
package enum CompanionHandOff {
    package static let serviceName = "crucible-pair"
    private static let hello = "CRUCIBLE-PAIR 1 "
    private static let declined = "DECLINED"
    package static let maximumLine = 4096

    package enum Answer: Equatable, Sendable {
        case invite(CompanionInvite)
        case declined
    }

    package static func helloLine(deviceName: String) -> Data {
        Data((hello + String(deviceName.filter { !$0.isNewline }.prefix(60)) + "\n").utf8)
    }

    /// The device name in an Apple TV's hello, or nil when the line is not one.
    package static func deviceName(inHello line: String) -> String? {
        guard line.hasPrefix(hello) else { return nil }
        let name = line.dropFirst(hello.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Apple TV" : String(name.prefix(60))
    }

    package static func answerLine(_ answer: Answer) -> Data {
        switch answer {
        case .invite(let invite): Data((invite.link.absoluteString + "\n").utf8)
        case .declined: Data((declined + "\n").utf8)
        }
    }

    package static func answer(inLine line: String) -> Answer? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == declined { return .declined }
        return URL(string: trimmed).flatMap(CompanionInvite.init(url:)).map(Answer.invite)
    }

    /// The first complete line in `buffer`, without its newline.
    package static func firstLine(in buffer: Data) -> String? {
        guard let end = buffer.firstIndex(of: 0x0A) else { return nil }
        return String(data: buffer[buffer.startIndex..<end], encoding: .utf8)
    }
}
