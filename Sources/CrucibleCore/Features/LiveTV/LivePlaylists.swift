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
    /// The XMLTV guides the viewer named, read beside the ones the playlist names itself: one per country is common.
    package var guideAddresses: [URL]
    package var userAgent: String?
    package let addedAt: Date

    package init(id: String = UUID().uuidString, name: String, address: URL, guideAddresses: [URL] = [], userAgent: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.address = address
        self.guideAddresses = guideAddresses
        self.userAgent = userAgent
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, guideAddresses, userAgent, addedAt
        case guideAddress
    }

    /// Reads a saved playlist, including one saved with a single `guideAddress` before a playlist could name several guides.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(URL.self, forKey: .address)
        if let guides = try container.decodeIfPresent([URL].self, forKey: .guideAddresses) {
            guideAddresses = guides
        } else {
            guideAddresses = try container.decodeIfPresent(URL.self, forKey: .guideAddress).map { [$0] } ?? []
        }
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(guideAddresses, forKey: .guideAddresses)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encode(addedAt, forKey: .addedAt)
    }

    /// The guide addresses as one line to edit, separated by spaces.
    package var guideAddressesText: String {
        guideAddresses.map(\.absoluteString).joined(separator: " ")
    }

    /// Every web address in what the viewer typed or pasted, split at spaces, commas and new lines.
    package static func addresses(from text: String) -> [URL] {
        text.split { $0.isWhitespace || $0 == "," }.filter { $0.contains(".") }.compactMap { address(from: String($0)) }
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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(id + ".") { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
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

/// Holds a playlist's airings in memory once read, as reading a large guide takes a moment. Each guide is read twice from
/// one unpacked copy: first its channels alone, to find which of them the playlist's channels are, then the airings of
/// those channels only, so a national guide of hundreds of channels costs no more memory than the few the playlist has.
actor PlaylistGuideStore {
    static let shared = PlaylistGuideStore()
    private var held: [String: (programmes: [String: [XMLTVGuide.Programme]], window: DateInterval, at: Date)] = [:]
    private var loading: [String: Task<[String: [XMLTVGuide.Programme]], Never>] = [:]

    /// The airings of each of `channels` (by channel id) covering `window`, read from the network when the copies on disk
    /// are old or missing.
    func programmes(for playlist: LivePlaylist, addresses: [URL], channels: [LiveChannel], covering window: DateInterval) async -> [String: [XMLTVGuide.Programme]] {
        if let cached = held[playlist.id], cached.window.start <= window.start, cached.window.end >= window.end, Date().timeIntervalSince(cached.at) < 3600 {
            return cached.programmes
        }
        if let running = loading[playlist.id] { return await running.value }
        let span = DateInterval(start: window.start.addingTimeInterval(-6 * 3600), end: max(window.end, Date().addingTimeInterval(36 * 3600)))
        let task = Task<[String: [XMLTVGuide.Programme]], Never>.detached(priority: .utility) {
            var found: [String: [XMLTVGuide.Programme]] = [:]
            for (index, address) in addresses.enumerated() {
                guard found.count < channels.count, let data = await Self.guideData(for: playlist, address: address, index: index) else { continue }
                do {
                    let bytes = try XMLTVGuide.unpack(data)
                    let directory = try XMLTVGuide.parse(bytes: bytes, includeProgrammes: false)
                    let names = PlaylistChannelSource.guideIndex(directory)
                    var wanted: [String: [String]] = [:]
                    for channel in channels where found[channel.id] == nil {
                        if let key = PlaylistChannelSource.match(channel, in: directory, index: names) { wanted[key, default: []].append(channel.id) }
                    }
                    guard !wanted.isEmpty else { continue }
                    let guide = try XMLTVGuide.parse(bytes: bytes, window: span, channelIDs: Set(wanted.keys))
                    for (key, ids) in wanted {
                        for id in ids { found[id] = guide.programmes[key] ?? [] }
                    }
                    MidgarLog.notice("Guide \(index + 1) of playlist \(playlist.name) matched \(wanted.count) channels", category: .liveTV)
                } catch {
                    MidgarLog.error("Guide \(index + 1) of playlist \(playlist.name) could not be read: \(error)", category: .liveTV)
                }
            }
            return found
        }
        loading[playlist.id] = task
        let programmes = await task.value
        loading[playlist.id] = nil
        held[playlist.id] = (programmes, span, Date())
        return programmes
    }

    func forget(id: String) {
        held[id] = nil
    }

    private static func guideData(for playlist: LivePlaylist, address: URL, index: Int) async -> Data? {
        let kind = "xmltv.\(LiveHash.fnv1a(address.absoluteString))"
        if PlaylistCache.isFresh(id: playlist.id, kind: kind), let cached = PlaylistCache.read(id: playlist.id, kind: kind) { return cached }
        do {
            let data = try await PlaylistFetch.data(address, userAgent: playlist.userAgent, timeout: 180)
            PlaylistCache.write(data, id: playlist.id, kind: kind)
            return data
        } catch {
            MidgarLog.error("Guide \(index + 1) of playlist \(playlist.name) failed to load: \(error.localizedDescription)", category: .liveTV)
            return PlaylistCache.read(id: playlist.id, kind: kind)
        }
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
        var seen = Set<URL>()
        let addresses = (playlist.guideAddresses + parsed.guideURLs).filter { seen.insert($0).inserted }
        guard !addresses.isEmpty else { return [:] }
        let all = Self.channels(of: playlist, in: parsed)
        let programmes = await PlaylistGuideStore.shared.programmes(for: playlist, addresses: addresses, channels: all, covering: window)
        let wanted = Set(channels.map(\.id))
        var result: [String: [LiveProgram]] = [:]
        for (id, list) in programmes where wanted.contains(id) {
            result[id] = LiveGuideMath.normalized(list.map { Self.program($0, channelID: id) }, in: window)
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
    /// country prefixes like "US:" and quality marks like "HD", else the guide channel whose name holds every word of the
    /// channel's with the fewest words besides ("Fox News" is "Fox News Channel", never "Fox News Radio Talk Live").
    static func match(_ channel: LiveChannel, in guide: XMLTVGuide, index: [String: String]) -> String? {
        if let key = channel.guideKey, guide.channels[key] != nil || guide.programmes[key] != nil { return key }
        if let key = channel.guideKey?.lowercased(),
           let found = guide.channels.keys.first(where: { $0.lowercased() == key }) ?? guide.programmes.keys.first(where: { $0.lowercased() == key }) {
            return found
        }
        if let exact = index[normalize(channel.title)] ?? channel.guideKey.flatMap({ index[normalize($0)] }) { return exact }
        let words = Set(normalize(channel.title).split(separator: " "))
        guard !words.isEmpty else { return nil }
        var best: (id: String, extra: Int)?
        for (name, id) in index {
            let other = Set(name.split(separator: " "))
            guard other.count > words.count, words.isSubset(of: other) else { continue }
            let extra = other.count - words.count
            guard extra <= 2 else { continue }
            if best == nil || extra < best!.extra || (extra == best!.extra && id < best!.id) { best = (id, extra) }
        }
        return best?.id
    }

    static func normalize(_ name: String) -> String {
        var text = name.lowercased()
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 8 { text = String(text[text.index(after: colon)...]) }
        let drop = ["fhd", "uhd", "hd", "sd", "4k", "hevc", "h265", "+1"]
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !drop.contains($0) && !($0.count == 1 && $0.first?.isLetter == true) }
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

/// Reads a playlist the viewer is adding, to tell them at once whether it works and how many channels it has.
package enum LivePlaylistCheck {
    package enum Outcome: Sendable, Equatable {
        case success(Int)
        case failure(String)
    }

    package static func check(_ playlist: LivePlaylist) async -> Outcome {
        do {
            let parsed = try await PlaylistChannelSource(playlist: playlist).loadPlaylist(forceRefresh: true)
            return .success(PlaylistChannelSource.channels(of: playlist, in: parsed).count)
        } catch M3UPlaylist.ParseError.notAPlaylist {
            return .failure(String(localized: "That address didn’t return a channel playlist (M3U).", comment: "Error when an added address is not an M3U playlist"))
        } catch M3UPlaylist.ParseError.empty {
            return .failure(String(localized: "The playlist has no channels.", comment: "Error when an added M3U playlist lists nothing"))
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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
