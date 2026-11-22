import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MidgarCore

/// A channel playlist the viewer added: an M3U address and, optionally, the XMLTV guide that goes with it. Both addresses
/// usually carry the viewer's credentials, so the whole list lives with the app's secrets (Keychain, Secret Service), never
/// in plain settings.
package struct LivePlaylist: Codable, Sendable, Hashable, Identifiable {
    package let id: String
    package var name: String
    package var address: URL
    package var guideAddress: URL?
    package var userAgent: String?
    package let addedAt: Date

    package init(id: String = UUID().uuidString, name: String, address: URL, guideAddress: URL? = nil, userAgent: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.address = address
        self.guideAddress = guideAddress
        self.userAgent = userAgent
        self.addedAt = addedAt
    }

    package var sourceID: LiveSourceID { LiveSourceID(kind: .playlist, key: id) }

    /// A name for a playlist the viewer did not name: the host it comes from, without `www.`.
    package static func suggestedName(for address: URL) -> String {
        let host = address.host ?? address.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Reads what the viewer typed or pasted as an address: http, https or a bare host, trimmed.
    package static func address(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// The viewer's playlists, kept with the app's secrets.
package enum LivePlaylistStore {
    private static let key = "livetv.playlists"

    package static func all() -> [LivePlaylist] {
        guard let text = KeychainHelper.load(key: key), let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LivePlaylist].self, from: data)) ?? []
    }

    package static func save(_ playlist: LivePlaylist) {
        var playlists = all()
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.append(playlist)
        }
        write(playlists)
    }

    package static func remove(id: String) {
        write(all().filter { $0.id != id })
        PlaylistCache.forget(id: id)
    }

    package static func removeAll() {
        for playlist in all() { PlaylistCache.forget(id: playlist.id) }
        KeychainHelper.delete(key: key)
        announce()
    }

    private static func write(_ playlists: [LivePlaylist]) {
        guard let data = try? JSONEncoder().encode(playlists), let text = String(data: data, encoding: .utf8) else { return }
        KeychainHelper.save(key: key, value: text)
        announce()
    }

    private static func announce() {
        Task { @MainActor in NotificationCenter.default.post(name: .liveSourcesChanged, object: nil) }
    }
}

extension Notification.Name {
    /// Posted on the main thread when a playlist was added, changed or removed.
    package static let liveSourcesChanged = Notification.Name("crucible.liveSourcesChanged")
}

/// What a playlist last said, kept on disk so the guide opens at once and still opens when the service is slow or down.
enum PlaylistCache {
    private static let freshFor: TimeInterval = 6 * 3600

    private static var directory: URL {
        AppPlatform.cachesDirectory.appendingPathComponent("LiveTV", isDirectory: true)
    }

    static func url(id: String, kind: String) -> URL {
        directory.appendingPathComponent("\(id).\(kind)")
    }

    static func read(id: String, kind: String, maxAge: TimeInterval? = nil) -> Data? {
        let file = url(id: id, kind: kind)
        if let maxAge {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) < maxAge else { return nil }
        }
        return try? Data(contentsOf: file)
    }

    static func write(_ data: Data, id: String, kind: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(id: id, kind: kind), options: .atomic)
    }

    static func isFresh(id: String, kind: String) -> Bool {
        read(id: id, kind: kind, maxAge: freshFor) != nil
    }

    static func forget(id: String) {
        for kind in ["m3u", "xmltv"] { try? FileManager.default.removeItem(at: url(id: id, kind: kind)) }
    }

    static func forgetAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Fetches what a playlist names with the user agent it asks for.
enum PlaylistFetch {
    enum Failure: Error, LocalizedError {
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .status(let code): return String(localized: "The playlist’s server answered \(code).", comment: "Error when an IPTV playlist could not be loaded; the number is an HTTP status")
            }
        }
    }

    static func data(_ url: URL, userAgent: String?, timeout: TimeInterval = 60) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent ?? LiveStreamRequest.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTPSession.current.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { throw Failure.status(status) }
        return data
    }
}

/// The user agent and headers a playlist's streams are asked for with.
package enum LiveStreamRequest {
    /// IPTV services often refuse unknown clients; VLC's agent is the one they all accept.
    package static let defaultUserAgent = "VLC/3.0.21 LibVLC/3.0.21"

    package static func headers(userAgent: String?, referrer: String?) -> [String: String] {
        var headers = ["User-Agent": userAgent ?? defaultUserAgent]
        if let referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        return headers
    }
}

/// Holds a playlist's parsed guide in memory once read, as parsing a large guide takes a moment.
actor PlaylistGuideStore {
    static let shared = PlaylistGuideStore()
    private var guides: [String: (guide: XMLTVGuide, window: DateInterval, at: Date)] = [:]
    private var loading: [String: Task<XMLTVGuide?, Never>] = [:]

    /// The playlist's guide covering `window`, read from the network when the copy on disk is old or missing.
    func guide(for playlist: LivePlaylist, addresses: [URL], channelIDs: Set<String>, covering window: DateInterval) async -> XMLTVGuide? {
        if let held = guides[playlist.id], held.window.start <= window.start, held.window.end >= window.end, Date().timeIntervalSince(held.at) < 3600 {
            return held.guide
        }
        if let running = loading[playlist.id] { return await running.value }
        let span = DateInterval(start: window.start.addingTimeInterval(-6 * 3600), end: max(window.end, Date().addingTimeInterval(36 * 3600)))
        let task = Task<XMLTVGuide?, Never> {
            guard let data = await Self.guideData(for: playlist, addresses: addresses) else { return nil }
            do {
                return try XMLTVGuide.parse(data, window: span, channelIDs: channelIDs.isEmpty ? nil : channelIDs)
            } catch {
                MidgarLog.error("The guide of playlist \(playlist.name) could not be read: \(error)", category: .liveTV)
                return nil
            }
        }
        loading[playlist.id] = task
        let guide = await task.value
        loading[playlist.id] = nil
        if let guide { guides[playlist.id] = (guide, span, Date()) }
        return guide
    }

    func forget(id: String) {
        guides[id] = nil
    }

    private static func guideData(for playlist: LivePlaylist, addresses: [URL]) async -> Data? {
        if PlaylistCache.isFresh(id: playlist.id, kind: "xmltv"), let cached = PlaylistCache.read(id: playlist.id, kind: "xmltv") { return cached }
        for address in addresses {
            do {
                let data = try await PlaylistFetch.data(address, userAgent: playlist.userAgent, timeout: 120)
                PlaylistCache.write(data, id: playlist.id, kind: "xmltv")
                return data
            } catch {
                MidgarLog.error("Guide of playlist \(playlist.name) failed to load: \(error.localizedDescription)", category: .liveTV)
            }
        }
        return PlaylistCache.read(id: playlist.id, kind: "xmltv")
    }
}

/// A playlist as a source of channels, with the guide its header or the viewer named.
package struct PlaylistChannelSource: LiveChannelSource {
    package let playlist: LivePlaylist
    package let records = false
    package var id: LiveSourceID { playlist.sourceID }
    package var title: String { playlist.name }

    package init(playlist: LivePlaylist) {
        self.playlist = playlist
    }

    package func channels() async throws -> [LiveChannel] {
        try await Self.channels(of: playlist, in: loadPlaylist())
    }

    /// The playlist's text, from the network when the copy on disk is more than a few hours old.
    func loadPlaylist(forceRefresh: Bool = false) async throws -> M3UPlaylist {
        if !forceRefresh, PlaylistCache.isFresh(id: playlist.id, kind: "m3u"), let cached = PlaylistCache.read(id: playlist.id, kind: "m3u"),
           let parsed = try? M3UPlaylist.parse(String(decoding: cached, as: UTF8.self)) {
            return parsed
        }
        do {
            let data = try await PlaylistFetch.data(playlist.address, userAgent: playlist.userAgent)
            let parsed = try M3UPlaylist.parse(String(decoding: data, as: UTF8.self))
            PlaylistCache.write(data, id: playlist.id, kind: "m3u")
            return parsed
        } catch {
            if let cached = PlaylistCache.read(id: playlist.id, kind: "m3u"), let parsed = try? M3UPlaylist.parse(String(decoding: cached, as: UTF8.self)) {
                MidgarLog.notice("Playlist \(playlist.name) failed to refresh, using the copy from before: \(error.localizedDescription)", category: .liveTV)
                return parsed
            }
            throw error
        }
    }

    /// The channels of a parsed playlist. A channel's id is a hash of its address, which never puts the address (and the
    /// credentials in it) into settings that remember favourites.
    static func channels(of playlist: LivePlaylist, in parsed: M3UPlaylist) -> [LiveChannel] {
        var seen = Set<String>()
        return parsed.entries.compactMap { entry in
            let id = "pl.\(playlist.id).\(LiveHash.fnv1a(entry.url.absoluteString))"
            guard seen.insert(id).inserted else { return nil }
            return LiveChannel(id: id, source: playlist.sourceID, number: entry.number, title: entry.title.isEmpty ? (entry.tvgName ?? entry.url.lastPathComponent) : entry.title,
                               logo: entry.logo, groups: entry.groups, isHD: entry.title.uppercased().contains("HD"),
                               guideKey: entry.tvgID ?? entry.tvgName ?? entry.title,
                               stream: .address(entry.url, userAgent: entry.userAgent ?? playlist.userAgent, referrer: entry.referrer))
        }
    }

    package func programs(for channels: [LiveChannel], in window: DateInterval) async throws -> [String: [LiveProgram]] {
        let parsed = try await loadPlaylist()
        let addresses = [playlist.guideAddress].compactMap { $0 } + parsed.guideURLs
        guard !addresses.isEmpty else { return [:] }
        let all = Self.channels(of: playlist, in: parsed)
        guard let guide = await PlaylistGuideStore.shared.guide(for: playlist, addresses: addresses, channelIDs: [], covering: window) else { return [:] }
        let index = Self.guideIndex(guide)
        var result: [String: [LiveProgram]] = [:]
        let wanted = Set(channels.map(\.id))
        for channel in all where wanted.contains(channel.id) {
            guard let key = Self.match(channel, in: guide, index: index), let programmes = guide.programmes[key] else { continue }
            result[channel.id] = LiveGuideMath.normalized(programmes.map { Self.program($0, channelID: channel.id) }, in: window)
        }
        return result
    }

    /// The guide's channel ids by their lowercased display names, for channels whose `tvg-id` is missing or wrong.
    static func guideIndex(_ guide: XMLTVGuide) -> [String: String] {
        var index: [String: String] = [:]
        for channel in guide.channels.values {
            for name in channel.names { index[normalize(name)] = index[normalize(name)] ?? channel.id }
        }
        return index
    }

    /// The guide channel that belongs to `channel`: its `tvg-id`, else a guide channel of the same name, ignoring case,
    /// country prefixes like "US:" and quality marks like "HD".
    static func match(_ channel: LiveChannel, in guide: XMLTVGuide, index: [String: String]) -> String? {
        if let key = channel.guideKey, guide.programmes[key] != nil { return key }
        if let key = channel.guideKey, let lowered = guide.programmes.keys.first(where: { $0.lowercased() == key.lowercased() }) { return lowered }
        return index[normalize(channel.title)] ?? channel.guideKey.flatMap { index[normalize($0)] }
    }

    static func normalize(_ name: String) -> String {
        var text = name.lowercased()
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 8 { text = String(text[text.index(after: colon)...]) }
        let drop = ["fhd", "uhd", "hd", "sd", "4k", "hevc", "h265", "+1"]
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !drop.contains($0) }
        let trimmed = words.drop { Int($0) != nil }
        return trimmed.joined(separator: " ")
    }

    static func program(_ programme: XMLTVGuide.Programme, channelID: String) -> LiveProgram {
        LiveProgram(id: "\(channelID)@\(Int(programme.start.timeIntervalSince1970))", channelID: channelID, title: programme.title,
                    episodeTitle: programme.subtitle, summary: programme.summary, start: programme.start, end: programme.stop, image: programme.icon,
                    season: programme.season, episode: programme.episode, genres: programme.categories, contentRating: programme.rating,
                    isNew: programme.isNew, isLive: programme.isLive, isPremiere: programme.isPremiere)
    }
}

/// A short stable hash for ids that must not carry the text they come from.
package enum LiveHash {
    package static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }
}
