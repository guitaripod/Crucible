import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The signed-in viewer's YouTube cookies, read by yt-dlp and cut down to the ones youtube.com needs. Only the header and
/// the SAPISID sign-in key leave this type; neither is ever logged.
package struct YouTubeCookies: Sendable {
    package let header: String
    package let sapisid: String

    /// Reads what yt-dlp wrote into a Netscape cookie file and keeps the youtube.com cookies that have not expired.
    package init?(netscape text: String, now: Date = Date()) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var line = String(line)
            if line.hasPrefix("#HttpOnly_") { line.removeFirst("#HttpOnly_".count) }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }
            let domain = fields[0].lowercased()
            guard domain.hasSuffix("youtube.com") else { continue }
            let expiry = Double(fields[4]) ?? 0
            guard expiry == 0 || Date(timeIntervalSince1970: expiry) > now else { continue }
            let name = fields[5]
            let value = fields[6]
            guard !name.isEmpty, !value.isEmpty else { continue }
            values[name] = value
        }
        guard !values.isEmpty, let sapisid = values["SAPISID"] ?? values["__Secure-3PAPISID"] else { return nil }
        header = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
        self.sapisid = sapisid
    }
}

/// Why the account's inbox could not be read.
package enum YouTubeInboxError: Error, Equatable, Sendable {
    /// The cookies are not a signed-in account's, or the account has been signed out.
    case signedOut
    case http(Int)
    case unreadable
}

/// The account's own YouTube inbox (`notification/get_notification_menu`), which is where replies, mentions and likes on
/// the viewer's comments arrive. It is read with the cookies yt-dlp already uses to sign in; nothing is fetched without
/// them, and nothing is ever written.
package struct YouTubeInbox: Sendable {
    package static let userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    private static let version = VersionBox()

    package init() {}

    /// The notes in the account's inbox, newest first, as far as the menu carries them.
    package func notes(cookies: YouTubeCookies, now: Date = Date()) async throws -> [WebNote] {
        let version = try await clientVersion(cookies: cookies)
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/notification/get_notification_menu?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "en", "gl": "US"]],
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookies.header, forHTTPHeaderField: "Cookie")
        request.setValue(sapisidHash(cookies.sapisid), forHTTPHeaderField: "Authorization")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeInboxError.unreadable }
        guard http.statusCode == 200 else { throw YouTubeInboxError.http(http.statusCode) }
        return try Self.notes(in: data, now: now)
    }

    /// Reads the notification renderers out of the menu's answer.
    package static func notes(in data: Data, now: Date = Date()) throws -> [WebNote] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeInboxError.unreadable }
        if let context = root["mainAppWebResponseContext"] as? [String: Any], context["loggedOut"] as? Bool == true {
            throw YouTubeInboxError.signedOut
        }
        var renderers: [[String: Any]] = []
        collect("notificationRenderer", in: root, into: &renderers)
        return renderers.compactMap { note(from: $0, now: now) }
    }

    private static func collect(_ key: String, in value: Any, into found: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if let matches = dictionary[key] as? [[String: Any]] { found += matches }
            else if let match = dictionary[key] as? [String: Any] { found.append(match) }
            for (name, child) in dictionary where name != key { collect(key, in: child, into: &found) }
        } else if let list = value as? [Any] {
            for child in list { collect(key, in: child, into: &found) }
        }
    }

    private static func note(from renderer: [String: Any], now: Date) -> WebNote? {
        guard let identifier = renderer["notificationId"] as? String else { return nil }
        let message = text(renderer["shortMessage"]) ?? ""
        let sent = text(renderer["sentTimeText"]).flatMap { relativeDate($0, now: now) } ?? now
        let navigation = renderer["navigationEndpoint"] as? [String: Any] ?? [:]
        let command = navigation["getCommentsFromInboxCommand"] as? [String: Any] ?? [:]
        let thumbnail = lastURL(renderer["videoThumbnail"])
        let videoID = command["videoId"] as? String
            ?? (navigation["watchEndpoint"] as? [String: Any])?["videoId"] as? String
            ?? (navigation["reelWatchEndpoint"] as? [String: Any])?["videoId"] as? String
            ?? videoID(in: thumbnail)
            ?? videoID(in: (navigation["commandMetadata"] as? [String: Any]).flatMap { (($0["webCommandMetadata"] as? [String: Any])?["url"]) as? String })
        let linked = command["linkedCommentId"] as? String
        let interpreted = interpret(message)
        let url = noteURL(videoID: videoID, linkedCommentID: linked, isShort: navigation["reelWatchEndpoint"] != nil)
        return WebNote(id: "n:\(identifier)", kind: interpreted.kind, title: interpreted.title,
                       channel: interpreted.channel, avatar: lastURL(renderer["thumbnail"]), videoID: videoID, thumbnail: thumbnail,
                       url: url, publishedAt: sent, isRead: renderer["read"] as? Bool ?? false)
    }

    /// What a notification's sentence says: who did it and, for a reply or mention, the comment itself. An empty title
    /// leaves the app to name what happened in its own words.
    static func interpret(_ message: String) -> (kind: WebNote.Kind, title: String, channel: String?) {
        let patterns: [(WebNote.Kind, String)] = [
            (.upload, #"^(.*?) uploaded: ?(.+)$"#),
            (.live, #"^(.*?) is live:? ?(.*)$"#),
            (.reply, #"^(.*?) replied to your comment:? ?(.*)$"#),
            (.reply, #"^(.*?) replied:? ?(.*)$"#),
            (.reply, #"^(.*?) commented on your (?:comment|post|video):? ?(.*)$"#),
            (.mention, #"^(.*?) mentioned you[^:]*:? ?(.*)$"#),
            (.reply, #"^Your comment got a reply from (.+)$"#),
            (.like, #"^Your comment got a .+ from (.+)$"#),
        ]
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { continue }
            func group(_ index: Int) -> String {
                guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: message) else { return "" }
                return String(message[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let channel = clean(group(1))
            let said = clean(group(2))
            switch kind {
            case .upload, .live:
                return (kind, said.isEmpty ? message : said, channel)
            case .reply, .mention, .like:
                return (kind, said, channel)
            default:
                return (kind, message, channel)
            }
        }
        return (.notice, message, nil)
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,:;!\"“”"))
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let simple = dictionary["simpleText"] as? String, !simple.isEmpty { return simple }
        if let runs = dictionary["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func lastURL(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any], let thumbnails = dictionary["thumbnails"] as? [[String: Any]] else { return nil }
        return thumbnails.last?["url"] as? String
    }

    private static func videoID(in address: String?) -> String? {
        guard let address else { return nil }
        for pattern in [#"/vi/([\w-]{11})/"#, #"[?&]v=([\w-]{11})"#, #"/shorts/([\w-]{11})"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
                  let range = Range(match.range(at: 1), in: address) else { continue }
            return String(address[range])
        }
        return nil
    }

    private static func noteURL(videoID: String?, linkedCommentID: String?, isShort: Bool) -> String {
        guard let videoID else { return "https://www.youtube.com/" }
        if isShort { return "https://www.youtube.com/shorts/\(videoID)" }
        var address = "https://www.youtube.com/watch?v=\(videoID)"
        if let linkedCommentID { address += "&lc=\(linkedCommentID)" }
        return address
    }

    /// "1 day ago", "2 weeks ago": how long before `now` the inbox said it arrived.
    static func relativeDate(_ text: String, now: Date = Date()) -> Date? {
        let pattern = #"(\d+)\s*(second|minute|hour|day|week|month|year)s?\s*ago"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let countRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
              let count = Double(text[countRange]) else { return nil }
        let seconds: Double
        switch text[unitRange].lowercased() {
        case "second": seconds = 1
        case "minute": seconds = 60
        case "hour": seconds = 3600
        case "day": seconds = 86_400
        case "week": seconds = 604_800
        case "month": seconds = 2_592_000
        default: seconds = 31_536_000
        }
        return now.addingTimeInterval(-count * seconds)
    }

    private func clientVersion(cookies: YouTubeCookies) async throws -> String {
        if let cached = Self.version.value { return cached }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/")!)
        request.timeoutInterval = 20
        request.setValue(cookies.header, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let pattern = #""INNERTUBE_CLIENT_VERSION":"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw YouTubeInboxError.unreadable
        }
        let version = String(html[range])
        Self.version.value = version
        return version
    }

    private func sapisidHash(_ sapisid: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let origin = "https://www.youtube.com"
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hash)"
    }
}

/// The client version read once a launch, shared by every request.
private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
