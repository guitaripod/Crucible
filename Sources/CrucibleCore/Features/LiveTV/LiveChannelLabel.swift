import Foundation

/// How a channel reads in the guide's narrow column: the number on its own, the station's name without the number and the
/// country an IPTV playlist writes in front of it ("01 US: ESPN", "UK | SKY SPORTS F1 FHD"), and the country and picture
/// quality as small tags beside the number, so the name gets the room and nothing is lost.
package struct LiveChannelLabel: Equatable, Sendable {
    /// The channel's number, from the source or from the front of its title, without leading zeros.
    package let number: String?
    /// The station's name as the source spells it, without the number, the country prefix or the quality mark.
    package let name: String
    /// The country or region code the title began with ("US", "UK", "DE").
    package let region: String?
    /// The quality the title names ("HD", "FHD", "4K").
    package let quality: String?

    private static let qualityMarks: [String: String] = [
        "hd": "HD", "fhd": "FHD", "fullhd": "FHD", "uhd": "4K", "4k": "4K", "8k": "8K", "720p": "HD", "1080p": "FHD", "1080i": "FHD",
        "2160p": "4K", "hevc": "HEVC", "sd": "SD", "ᴴᴰ": "HD", "ʰᵈ": "HD",
    ]
    private static let regionSeparators: Set<Character> = [":", "|", "-"]
    /// Country codes a playlist may write before a name with nothing between ("US CNN"), which only these count as.
    private static let knownRegions: Set<String> = [
        "US", "USA", "UK", "GB", "CA", "AU", "NZ", "IE", "DE", "AT", "CH", "FR", "BE", "NL", "LU", "ES", "PT", "IT", "SE", "NO", "DK", "FI",
        "IS", "PL", "CZ", "SK", "HU", "RO", "BG", "GR", "TR", "RU", "UA", "IL", "AE", "SA", "IN", "PK", "BR", "AR", "MX", "CL", "CO", "ZA",
        "JP", "KR", "CN", "HK", "TW", "PH", "TH", "VN", "ID", "MY", "SG", "EX", "LAT", "AFR", "ARAB",
    ]
    /// Marks that say nothing about the station: codecs, frame rates and feed labels.
    private static let noise: Set<String> = ["hevc", "h265", "h264", "x265", "50fps", "60fps", "25fps", "30fps", "raw", "vip", "backup", "bkp"]

    package init(_ channel: LiveChannel) {
        self.init(title: channel.title, number: channel.number)
    }

    package init(title: String, number: String?) {
        var text = title.trimmingCharacters(in: .whitespaces)
        var found = number.flatMap { $0.isEmpty ? nil : $0 }
        if let space = text.firstIndex(where: \.isWhitespace) {
            let head = String(text[..<space])
            let rest = text[space...].trimmingCharacters(in: .whitespaces)
            if head.allSatisfy(\.isNumber), !rest.isEmpty, head == found || head.hasPrefix("0") || found == nil && (Self.startsWithRegion(rest) || Self.startsWithKnownRegion(rest) || Self.startsWithMark(rest)) {
                found = found ?? head
                text = rest
            }
        }
        var region: String?
        var leadingQuality: String?
        if let first = text.first, "[(".contains(first), let close = text.firstIndex(where: { "])".contains($0) }),
           text.distance(from: text.startIndex, to: close) <= 5 {
            let code = text[text.index(after: text.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            if Self.isRegion(code) {
                region = code.uppercased()
                text = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            }
        } else if let separator = text.firstIndex(where: { Self.regionSeparators.contains($0) }), text.distance(from: text.startIndex, to: separator) <= 8 {
            let rawCode = text[..<separator].trimmingCharacters(in: .whitespaces)
            let dashOK = text[separator] != "-" || text[text.index(after: separator)...].first?.isWhitespace == true
            if dashOK, let split = Self.regionAndQuality(rawCode) {
                region = split.region
                text = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if let mark = split.quality { leadingQuality = mark }
            }
        }
        if region == nil, let space = text.firstIndex(of: " ") {
            let head = String(text[..<space])
            if head == head.uppercased(), Self.knownRegions.contains(head), text[space...].trimmingCharacters(in: .whitespaces).count > 1 {
                region = head
                text = text[space...].trimmingCharacters(in: .whitespaces)
            }
        }
        var quality: String? = leadingQuality
        var words = text.split(separator: " ").map(String.init)
        func mark(of word: String) -> String? { Self.qualityMarks[word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))] }
        func isNoise(_ word: String) -> Bool { Self.noise.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))) }
        while words.count > 1, mark(of: words[0]) != nil || isNoise(words[0]) {
            if let found = mark(of: words[0]), found != "HEVC", quality == nil || quality == "HEVC" { quality = found }
            words.removeFirst()
        }
        while words.count > 1, mark(of: words.last!) != nil || isNoise(words.last!) {
            if let found = mark(of: words.last!), quality == nil || quality == "HEVC" { quality = found }
            words.removeLast()
        }
        if quality == "HEVC" { quality = nil }
        self.number = found.map { $0.drop { $0 == "0" }.isEmpty ? $0 : String($0.drop { $0 == "0" }) }
        self.name = words.isEmpty ? title : words.joined(separator: " ")
        self.region = region
        self.quality = quality
    }

    /// The small tags shown beside the number: the region, then the quality.
    package var tags: [String] { [region, quality].compactMap { $0 } }

    /// A prefix before a separator read as a region, with a quality fused onto it ("UKFHD", "DE HD"), or nil when it is not one.
    private static func regionAndQuality(_ code: String) -> (region: String, quality: String?)? {
        let compact = code.replacingOccurrences(of: " ", with: "")
        if isRegion(compact) { return (compact.uppercased(), nil) }
        for (mark, label) in qualityMarks.sorted(by: { $0.key.count > $1.key.count }) where compact.lowercased().hasSuffix(mark) {
            let head = String(compact.dropLast(mark.count))
            if isRegion(head) { return (head.uppercased(), label == "HEVC" ? nil : label) }
        }
        return nil
    }

    private static func isRegion(_ code: String) -> Bool {
        (2...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func startsWithRegion(_ text: String) -> Bool {
        guard let separator = text.firstIndex(where: { regionSeparators.contains($0) }), text.distance(from: text.startIndex, to: separator) <= 8 else { return false }
        return regionAndQuality(text[..<separator].trimmingCharacters(in: .whitespaces)) != nil
    }

    private static func startsWithMark(_ text: String) -> Bool {
        let head = text.prefix { !$0.isWhitespace }.lowercased()
        return qualityMarks[head] != nil || noise.contains(head)
    }

    private static func startsWithKnownRegion(_ text: String) -> Bool {
        guard let space = text.firstIndex(of: " ") else { return false }
        let head = String(text[..<space])
        return head == head.uppercased() && knownRegions.contains(head)
    }
}
