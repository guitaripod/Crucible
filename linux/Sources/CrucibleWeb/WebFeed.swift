import Foundation

/// A channel's public feed of its newest uploads (`youtube.com/feeds/videos.xml?channel_id=`): no account, no key and no
/// yt-dlp run, which is what lets a subscriptions page of a hundred channels refresh in a moment.
package struct WebFeed: Sendable, Equatable {
    package let channel: String?
    package let channelID: String?
    package let entries: [WebEntry]

    /// The feed's address for a channel ("UC…").
    package static func address(channelID: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")
        components?.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
        return components?.url
    }

    /// Reads the feed's Atom document. The few tags it uses are read by hand, so no XML library is linked for it.
    package init?(atom data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("<feed") else { return nil }
        let head = text.range(of: "<entry>").map { String(text[..<$0.lowerBound]) } ?? text
        let feedChannel = Self.content(of: "title", in: head)
        let feedChannelID = Self.content(of: "yt:channelId", in: head).map { $0.hasPrefix("UC") ? $0 : "UC" + $0 }
        var entries: [WebEntry] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<entry>"), let close = rest.range(of: "</entry>", range: open.upperBound..<rest.endIndex) {
            let block = String(rest[open.upperBound..<close.lowerBound])
            rest = rest[close.upperBound...]
            guard let id = Self.content(of: "yt:videoId", in: block), let title = Self.content(of: "title", in: block) else { continue }
            let link = Self.attribute("href", of: "link", in: block) ?? "https://www.youtube.com/watch?v=\(id)"
            let channelID = Self.content(of: "yt:channelId", in: block) ?? feedChannelID
            entries.append(WebEntry(
                id: id, url: link, title: title, channel: Self.content(of: "name", in: block) ?? feedChannel, channelID: channelID,
                channelURL: channelID.map { "https://www.youtube.com/channel/\($0)" },
                viewCount: Self.attribute("views", of: "media:statistics", in: block).flatMap(Int.init),
                published: Self.content(of: "published", in: block).flatMap(Self.date),
                thumbnail: Self.attribute("url", of: "media:thumbnail", in: block), isShort: link.contains("/shorts/")))
        }
        channel = feedChannel
        channelID = feedChannelID ?? entries.first?.channelID
        self.entries = entries
    }

    private static func content(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = unescaped(String(text[open.upperBound..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func attribute(_ name: String, of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag) "), let end = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
        let inside = text[open.upperBound..<end.lowerBound]
        guard let start = inside.range(of: "\(name)=\""), let stop = inside.range(of: "\"", range: start.upperBound..<inside.endIndex) else { return nil }
        return unescaped(String(inside[start.upperBound..<stop.lowerBound]))
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// Turns XML's character references back into the characters they stand for.
    static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[ampersand...]
            guard let semicolon = tail.firstIndex(of: ";"), tail.distance(from: ampersand, to: semicolon) <= 9 else {
                result.append("&")
                rest = tail.dropFirst()
                continue
            }
            let name = tail[tail.index(after: ampersand)..<semicolon]
            switch name {
            case "amp": result.append("&")
            case "lt": result.append("<")
            case "gt": result.append(">")
            case "quot": result.append("\"")
            case "apos": result.append("'")
            default:
                let number = name.hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16) : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
                if let number, let scalar = Unicode.Scalar(number) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += tail[...semicolon]
                }
            }
            rest = tail[tail.index(after: semicolon)...]
        }
        return result + rest
    }
}
