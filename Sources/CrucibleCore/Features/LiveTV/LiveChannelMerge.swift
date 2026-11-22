import Foundation

/// Folds the copies of one channel into a single row: the same station offered by several playlists, by a playlist and
/// Plex, or by one playlist in HD, FHD, 4K and a backup feed. Channels are the same when their names agree once case,
/// accents, punctuation, quality marks ("HD", "FHD", "4K", "HEVC", "1080p"), feed marks ("Backup", "Alt") and a leading
/// region ("UK:", "[US]", "DE |") are set aside, or when two playlists give them the same `tvg-id`. A region, a timeshift
/// ("+1"), a regional name ("BBC One Scotland") keeps channels apart, while a number spelt out matches its digit ("BBC One" is "BBC 1"), and two channels of one
/// Plex tuner are never folded. The copy kept is the best one: a tuner first, then one with a guide, then the sharpest
/// picture, then the source listed first; the others stay behind it as alternates the player falls back to.
package enum LiveChannelMerge {
    package struct Result: Sendable, Equatable {
        /// The channels in the guide, one per station, in the order the first copy of each came.
        package let channels: [LiveChannel]
        /// The other copies of each kept channel, best first, by the kept channel's id.
        package let alternates: [String: [LiveChannel]]
        /// The kept channel's id for every folded copy's id.
        package let canonical: [String: String]
    }

    package static func merge(_ channels: [LiveChannel]) -> Result {
        let keys = channels.map(Key.init)
        var parent = Array(channels.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var tuners: [Int: Set<LiveSourceID>] = [:]
        for (index, channel) in channels.enumerated() where channel.source.kind == .plexDVR { tuners[index] = [channel.source] }
        func join(_ lhs: Int, _ rhs: Int) {
            let (a, b) = (root(lhs), root(rhs))
            guard a != b, tuners[a, default: []].isDisjoint(with: tuners[b, default: []]) else { return }
            let (kept, folded) = (min(a, b), max(a, b))
            parent[folded] = kept
            tuners[kept, default: []].formUnion(tuners.removeValue(forKey: folded) ?? [])
        }
        var byName: [String: Int] = [:]
        var byGuide: [String: Int] = [:]
        for (index, key) in keys.enumerated() {
            if let name = key.name {
                if let first = byName[name] { join(first, index) } else { byName[name] = index }
            }
            if let guide = key.guide {
                if let first = byGuide[guide] {
                    if !keys[first].isSibling(of: key) { join(first, index) }
                } else {
                    byGuide[guide] = index
                }
            }
        }
        var clusters: [Int: [Int]] = [:]
        var order: [Int] = []
        for index in channels.indices {
            let group = root(index)
            if clusters[group] == nil { order.append(group) }
            clusters[group, default: []].append(index)
        }
        var kept: [LiveChannel] = []
        var alternates: [String: [LiveChannel]] = [:]
        var canonical: [String: String] = [:]
        for group in order {
            let members = clusters[group, default: []].sorted { rank(channels[$0], keys[$0], at: $0) > rank(channels[$1], keys[$1], at: $1) }
            guard let best = members.first else { continue }
            let others = members.dropFirst().map { channels[$0] }
            let chosen = others.isEmpty ? channels[best] : enriched(channels[best], with: others)
            kept.append(chosen)
            if !others.isEmpty {
                alternates[chosen.id] = others
                for other in others { canonical[other.id] = chosen.id }
            }
        }
        return Result(channels: kept, alternates: alternates, canonical: canonical)
    }

    /// The order copies are preferred in: a tuner, a guide, the sharpest picture, the earliest source.
    private static func rank(_ channel: LiveChannel, _ key: Key, at index: Int) -> (Int, Int, Int, Int) {
        let source = switch channel.source.kind {
        case .plexDVR: 2
        case .playlist: 1
        case .plexFree: 0
        }
        return (source, key.guide != nil || channel.source.kind != .playlist ? 1 : 0, key.quality + (channel.isHD ? 1 : 0), -index)
    }

    /// The kept copy with what the others add: a number, a logo, a summary and every group any copy is filed under.
    private static func enriched(_ channel: LiveChannel, with others: [LiveChannel]) -> LiveChannel {
        var groups = channel.groups
        for group in others.flatMap(\.groups) where !groups.contains(group) { groups.append(group) }
        return LiveChannel(id: channel.id, source: channel.source, number: channel.number ?? others.lazy.compactMap(\.number).first,
                           title: channel.title, logo: channel.logo ?? others.lazy.compactMap(\.logo).first, groups: groups,
                           isHD: channel.isHD, guideKey: channel.guideKey, stream: channel.stream,
                           summary: channel.summary ?? others.lazy.compactMap(\.summary).first)
    }

    /// What two copies of a channel share.
    struct Key {
        /// The station's name with region kept and quality and feed marks dropped; nil when nothing is left of it.
        let name: String?
        /// A playlist's `tvg-id`, when it is an id rather than the name the playlist fell back to.
        let guide: String?
        /// How sharp the name says the picture is: 0 SD or unmarked, 2 HD, 3 FHD, 4 UHD.
        let quality: Int
        let words: Set<String>

        init(_ channel: LiveChannel) {
            let parsed = Self.parse(Self.withoutLeadingNumber(channel.title, number: channel.number))
            name = parsed.name
            quality = parsed.quality
            words = Set(parsed.name?.split(separator: " ").map(String.init) ?? [])
            if channel.source.kind == .playlist, let raw = channel.guideKey?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
               raw != channel.title, !raw.contains(where: \.isWhitespace) {
                guide = "\(raw.lowercased())|\(parsed.timeshift ?? "")"
            } else {
                guide = nil
            }
        }

        /// Whether the names share a word yet each adds words the other lacks, the way regional editions sharing one `tvg-id` do ("BBC One
        /// London", "BBC One Scotland").
        func isSibling(of other: Key) -> Bool {
            !words.isDisjoint(with: other.words) && !words.isSubset(of: other.words) && !other.words.isSubset(of: words)
        }

        private static let numberWords: [String: String] = [
            "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        ]
        private static let qualityMarks: [String: Int] = [
            "sd": 0, "480p": 0, "576p": 0, "hd": 2, "720p": 2, "hq": 2, "fhd": 3, "1080p": 3, "1080i": 3, "fullhd": 3,
            "uhd": 4, "4k": 4, "2160p": 4, "8k": 4, "ᴴᴰ": 2, "ʰᵈ": 2,
        ]
        private static let noiseMarks: Set<String> = ["hevc", "h265", "h264", "x265", "x264", "avc", "backup", "alt", "bkp", "mirror",
                                                      "raw", "vip", "multi", "audio", "geo", "blocked", "50fps", "60fps", "fps"]
        private static let regionSeparators: Set<Character> = [":", "|", "-", "/"]

        /// The title without a channel number written in front of it ("01 US: ESPN", "7 News" when the channel is 7), which
        /// differs between sources; a number that is part of the name ("5 Star", "4Music") stays.
        static func withoutLeadingNumber(_ title: String, number: String?) -> String {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
            let head = String(trimmed[..<space])
            guard head.allSatisfy(\.isNumber) else { return trimmed }
            let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
            let restHasRegion = rest.prefix(6).contains { ":|[".contains($0) }
            guard !rest.isEmpty, head.hasPrefix("0") || head == number || restHasRegion else { return trimmed }
            return rest
        }

        /// Splits a channel's title into the station's name, its timeshift and how sharp the name says the picture is.
        static func parse(_ title: String) -> (name: String?, timeshift: String?, quality: Int) {
            var text = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            var region: String?
            if let first = text.first, "[(".contains(first), let close = text.firstIndex(where: { "])".contains($0) }),
               text.distance(from: text.startIndex, to: close) <= 6 {
                region = String(text[text.index(after: text.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                text = String(text[text.index(after: close)...])
            } else if let separator = text.firstIndex(where: { regionSeparators.contains($0) }),
                      text.distance(from: text.startIndex, to: separator) <= 5 {
                let head = text[..<separator].trimmingCharacters(in: .whitespaces)
                let spaced = text[text.index(after: separator)...].first?.isWhitespace == true
                if !head.isEmpty, head.count <= 4, head.allSatisfy(\.isLetter), spaced || ":|".contains(text[separator]) {
                    region = head
                    text = String(text[text.index(after: separator)...])
                }
            }
            var quality = 0
            var timeshift: String?
            var words: [String] = []
            let tokens = text.replacingOccurrences(of: "+", with: " +").split { !$0.isLetter && !$0.isNumber && $0 != "+" }
            for token in tokens.map(String.init) {
                if token.hasPrefix("+"), token.count > 1, Int(token.dropFirst()) != nil {
                    timeshift = token
                } else if let mark = qualityMarks[token] {
                    quality = max(quality, mark)
                } else if noiseMarks.contains(token) || token == "+" {
                    continue
                } else {
                    words.append(numberWords[token] ?? token)
                }
            }
            guard !words.isEmpty else { return (nil, timeshift, quality) }
            let name = ([region ?? ""] + words + [timeshift ?? ""]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (name, timeshift, quality)
        }
    }
}

/// Whether the guide folds copies of a channel into one row, on unless the viewer turned it off.
extension LiveTVPreferences {
    private static let mergeKey = "liveTVMergesDuplicates"

    package static var mergesDuplicates: Bool {
        get { UserDefaults.standard.object(forKey: mergeKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: mergeKey)
            Task { @MainActor in NotificationCenter.default.post(name: .liveSourcesChanged, object: nil) }
        }
    }
}
