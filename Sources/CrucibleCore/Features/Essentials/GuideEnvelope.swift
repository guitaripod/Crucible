import CryptoKit
import Foundation

/// The signed form Crucible Guides is served in. The signature covers the header and the bundle's bytes,
/// so an old bundle cannot be replayed under a new sequence and a header cannot be edited.
package struct GuideEnvelope: Decodable, Sendable {
    package let format: Int
    package let keyId: String
    package let sequence: Int
    package let notAfter: String
    package let payload: String
    package let signature: String

    package enum Refusal: Error, Equatable {
        case malformed
        case unknownKey
        case badSignature
        case expired
        case notNewer
    }

    /// The Ed25519 keys the bundle may be signed with, by key id: the current one and the next, so the key can
    /// rotate without an app release. The private halves live only in Midgar's vault.
    package static let trustedKeys: [String: String] = [
        "cg1": "TggMVn92GnaMgBApPJ+LA0E7xnYvD71pQ1z6pa7KN6M=",
        "cg2": "NvXsqvvLubalXUT+HDNd1mJdkn18fzv4rxTPybk0GAM=",
    ]

    /// The bundle this envelope carries, when a trusted key signed it, it has not expired and it is newer than
    /// `after` (the sequence already in use).
    package func open(keys: [String: String] = trustedKeys, now: Date = Date(), after: Int = 0) throws(Refusal) -> GuideBundle {
        guard format == 1, let keyText = keys[keyId] else { throw .unknownKey }
        guard let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let body = Data(base64Encoded: payload),
              let signed = Data(base64Encoded: signature) else { throw .malformed }
        guard key.isValidSignature(signed, for: Self.message(format: format, keyId: keyId, sequence: sequence, notAfter: notAfter, payload: body)) else {
            throw .badSignature
        }
        guard let expiry = Self.day(notAfter), now < expiry.addingTimeInterval(86_400) else { throw .expired }
        guard sequence > after else { throw .notNewer }
        guard let bundle = try? JSONDecoder().decode(GuideBundle.self, from: body), bundle.format == 1 else { throw .malformed }
        return bundle
    }

    /// The exact bytes the builder signs: `crucible-guides`, the format, key id, sequence and expiry, one per line, then the payload.
    package static func message(format: Int, keyId: String, sequence: Int, notAfter: String, payload: Data) -> Data {
        var data = Data("crucible-guides\n\(format)\n\(keyId)\n\(sequence)\n\(notAfter)\n".utf8)
        data.append(payload)
        return data
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
