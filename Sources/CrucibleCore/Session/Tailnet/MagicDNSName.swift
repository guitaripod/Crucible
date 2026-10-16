import Foundation

/// The MagicDNS labels a Plex server's friendly name could have become. Plex names a server after
/// its computer and Tailscale names a device after the same computer, so the two usually match, but
/// each sanitizes differently. Every guess is checked against the server's machine identifier
/// before it is trusted, so a wrong guess costs a lookup and nothing else.
package enum MagicDNSName {
    private static let limit = 4

    package static func candidates(forServerNamed name: String) -> [String] {
        let hyphenated = label(from: name, separator: "-")
        let joined = label(from: name, separator: "")
        let firstWord = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
            .first
            .map { label(from: String($0), separator: "") } ?? ""
        var seen = Set<String>()
        return [hyphenated, joined, firstWord]
            .filter { !$0.isEmpty && $0.count <= 63 && seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Lowercase letters and digits, with runs of whitespace, dots, dashes and underscores becoming
    /// `separator` and everything else (apostrophes, accents) dropped.
    private static func label(from text: String, separator: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result += separator }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespaces.contains(scalar) || "-_.".unicodeScalars.contains(scalar) {
                pendingSeparator = true
            }
        }
        return result
    }
}
