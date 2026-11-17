import Foundation

/// What a pasted address points at, so the right thing opens: a video plays, a playlist or a channel shows its page, and
/// anything else is handed to yt-dlp, which knows well over a thousand sites.
package enum WebLink: Equatable, Sendable {
    /// A video, with the moment its link starts at when it names one ("t=1m30s").
    case video(url: String, start: Double?)
    case playlist(url: String)
    case channel(url: String)
    case other(url: String)

    package init?(_ text: String) {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(" ") else { return nil }
        if !address.contains("://") {
            guard address.contains("."), !address.hasPrefix(".") else { return nil }
            address = "https://" + address
        }
        guard let components = URLComponents(string: address), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), host.contains(".") else { return nil }
        guard Self.isYouTube(host) else {
            self = .other(url: address)
            return
        }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        let parts = components.path.split(separator: "/").map(String.init)
        let start = (query["t"] ?? query["start"]).flatMap(Self.seconds)
        if host == "youtu.be", let id = parts.first {
            self = .video(url: "https://www.youtube.com/watch?v=\(id)", start: start)
        } else if parts.first == "watch", let id = query["v"] {
            self = .video(url: "https://www.youtube.com/watch?v=\(id)", start: start)
        } else if ["shorts", "live", "embed", "v"].contains(parts.first ?? ""), parts.count >= 2 {
            self = .video(url: parts[0] == "shorts" ? "https://www.youtube.com/shorts/\(parts[1])" : "https://www.youtube.com/watch?v=\(parts[1])", start: start)
        } else if parts.first == "playlist", let list = query["list"] {
            self = .playlist(url: "https://www.youtube.com/playlist?list=\(list)")
        } else if let first = parts.first, first.hasPrefix("@") || (["channel", "c", "user"].contains(first) && parts.count >= 2) {
            let root = first.hasPrefix("@") ? first : "\(first)/\(parts[1])"
            self = .channel(url: "https://www.youtube.com/\(root)")
        } else {
            self = .other(url: address)
        }
    }

    package var url: String {
        switch self {
        case .video(let url, _), .playlist(let url), .channel(let url), .other(let url): url
        }
    }

    static func isYouTube(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    /// The video a YouTube address names, in any of the shapes its links take.
    package static func youTubeVideoID(in address: String) -> String? {
        guard let components = URLComponents(string: address), let host = components.host?.lowercased(), isYouTube(host) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        if host == "youtu.be" { return parts.first }
        if parts.first == "watch" { return components.queryItems?.first { $0.name == "v" }?.value }
        if ["shorts", "live", "embed", "v"].contains(parts.first ?? ""), parts.count >= 2 { return parts[1] }
        return nil
    }

    /// The seconds a link's start names: "90", "90s", "1m30s" or "1h2m3s".
    static func seconds(_ text: String) -> Double? {
        if let plain = Double(text) { return plain >= 0 ? plain : nil }
        var total = 0.0
        var digits = ""
        for character in text.lowercased() {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let value = Double(digits) else { return nil }
            digits = ""
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
        }
        guard digits.isEmpty else { return nil }
        return total > 0 ? total : nil
    }
}
