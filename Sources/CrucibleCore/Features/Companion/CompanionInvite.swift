import CryptoKit
import Foundation

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
        let hosts = (value("hosts") ?? "").split(separator: ",").map(String.init).filter(Self.isHost)
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

    /// `host:port` or `[v6]:port`, nothing that could carry a path or credentials.
    private static func isHost(_ text: String) -> Bool {
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
