import Foundation
import MidgarCore

/// The Live TV screen's state on every platform: the sources there are, their channels, the filter the viewer picked, the
/// airings loaded so far for the rows on screen, favourites and the channels watched last. Screens render it and tell it
/// which channels they show; it never touches UI.
@MainActor
package final class LiveTVGuide {
    package enum Filter: Hashable, Sendable {
        case all
        case favorites
        case recent
        case source(LiveSourceID)
        case group(String)
    }

    package enum State: Equatable, Sendable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    package struct Context: Sendable {
        package let api: APIClient?
        package let token: String
        package let machineIdentifier: String?
        package let serverName: String?

        package init(api: APIClient?, token: String, machineIdentifier: String?, serverName: String?) {
            self.api = api
            self.token = token
            self.machineIdentifier = machineIdentifier
            self.serverName = serverName
        }

        /// The context of the saved server, for a screen opened without the launch's payload.
        package static func current(api: APIClient) -> Context {
            let connection = ServerBootstrap.connection()
            return Context(api: api, token: ServerBootstrap.plexTVToken ?? api.token, machineIdentifier: connection?.machineIdentifier,
                           serverName: connection?.serverName)
        }

        /// The context of the server the app connected to: its client for a tuner, the plex.tv token for Plex's free channels.
        package init(payload: LaunchPayload) {
            self.init(api: payload.api, token: payload.connection.plexTVToken, machineIdentifier: payload.connection.machineIdentifier,
                      serverName: payload.connection.serverName)
        }
    }

    /// How far ahead the guide reads airings.
    package static let guideHours: Double = 12

    package let context: Context
    package private(set) var state: State = .loading
    package private(set) var sources: [any LiveChannelSource] = []
    package private(set) var summaries: [LiveSourceSummary] = []
    package private(set) var channels: [LiveChannel] = []
    package private(set) var programs: [String: [LiveProgram]] = [:]
    /// Sources that failed to load, with why, so the screen can say so beside the channels that did.
    package private(set) var failures: [LiveSourceID: String] = [:]
    package var filter: Filter = .all {
        didSet {
            guard filter != oldValue else { return }
            LiveTVPreferences.lastFilter = filter
            onChange?()
        }
    }

    /// Called whenever the channel list, the state or the filter changed.
    package var onChange: (() -> Void)?
    /// Called with the channel ids whose airings arrived.
    package var onPrograms: ((Set<String>) -> Void)?

    nonisolated(unsafe) private var loadTask: Task<Void, Never>?
    nonisolated(unsafe) private var programTasks: [String: Task<Void, Never>] = [:]
    private var requested: Set<String> = []
    private var requestedAt: [String: Date] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    package init(context: Context) {
        self.context = context
        filter = LiveTVPreferences.lastFilter ?? .all
        observers.append(NotificationCenter.default.addObserver(forName: .liveSourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load(force: true) }
        })
    }

    deinit {
        loadTask?.cancel()
        for task in programTasks.values { task.cancel() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Whether any source can record, which decides whether the Recordings entry shows.
    package var canRecord: Bool { summaries.contains { $0.records } }

    /// The channels the filter keeps, favourites first in the All view's order otherwise.
    package var visibleChannels: [LiveChannel] {
        switch filter {
        case .all: return channels
        case .favorites:
            let favorites = LiveTVPreferences.favorites
            return channels.filter { favorites.contains($0.id) }
        case .recent:
            let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return LiveTVPreferences.recentChannels.compactMap { byID[$0] }
        case .source(let id): return channels.filter { $0.source == id }
        case .group(let name): return channels.filter { $0.groups.contains(name) }
        }
    }

    /// The groups the channels are filed under, the largest first, at most `limit`.
    package func groups(limit: Int = 30) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for channel in channels { for group in channel.groups { counts[group, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// The filters worth offering: All, Favourites and Recent when they hold anything, each source when there are several,
    /// then the groups.
    package func filters() -> [Filter] {
        var result: [Filter] = [.all]
        if !LiveTVPreferences.favorites.isEmpty { result.append(.favorites) }
        if !LiveTVPreferences.recentChannels.isEmpty { result.append(.recent) }
        if summaries.count > 1 { result += summaries.map { .source($0.id) } }
        result += groups().map { .group($0.name) }
        return result
    }

    package func title(of filter: Filter) -> String {
        switch filter {
        case .all: return LiveTVCopy.allChannels
        case .favorites: return LiveTVCopy.favorites
        case .recent: return LiveTVCopy.recent
        case .source(let id): return summaries.first { $0.id == id }?.title ?? LiveTVCopy.title
        case .group(let name): return name
        }
    }

    /// Reads every source's channels; with `force`, playlists are asked again instead of taken from the copy on disk.
    package func load(force: Bool = false) {
        loadTask?.cancel()
        if channels.isEmpty { state = .loading }
        onChange?()
        let context = context
        loadTask = Task { [weak self] in
            let sources = await Self.discoverSources(context: context)
            var loaded: [(any LiveChannelSource, Result<[LiveChannel], Error>)] = []
            await withTaskGroup(of: (Int, Result<[LiveChannel], Error>).self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        do {
                            if force, let playlist = source as? PlaylistChannelSource {
                                return (index, .success(PlaylistChannelSource.channels(of: playlist.playlist, in: try await playlist.loadPlaylist(forceRefresh: true))))
                            }
                            return (index, .success(try await source.channels()))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var byIndex: [Int: Result<[LiveChannel], Error>] = [:]
                for await (index, result) in group { byIndex[index] = result }
                loaded = sources.enumerated().map { ($0.element, byIndex[$0.offset] ?? .success([])) }
            }
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded)
        }
    }

    private func apply(_ loaded: [(any LiveChannelSource, Result<[LiveChannel], Error>)]) {
        var channels: [LiveChannel] = []
        var summaries: [LiveSourceSummary] = []
        var failures: [LiveSourceID: String] = [:]
        for (source, result) in loaded {
            switch result {
            case .success(let found):
                channels += found
                if !found.isEmpty { summaries.append(LiveSourceSummary(id: source.id, title: source.title, channelCount: found.count, records: source.records)) }
            case .failure(let error):
                MidgarLog.error("Live TV source \(source.id) failed: \(error)", category: .liveTV)
                failures[source.id] = LiveTVCopy.failure(error, source: source.title)
            }
        }
        sources = loaded.map(\.0)
        self.channels = channels
        self.summaries = summaries
        self.failures = failures
        requested.removeAll()
        if case .source(let id) = filter, !summaries.contains(where: { $0.id == id }) { filter = .all }
        if case .group(let name) = filter, !channels.contains(where: { $0.groups.contains(name) }) { filter = .all }
        if channels.isEmpty {
            state = failures.isEmpty ? .empty : .failed(failures.values.sorted().joined(separator: "\n"))
        } else {
            state = .ready
        }
        MidgarLog.notice("Live TV has \(channels.count) channels from \(summaries.count) sources", category: .liveTV)
        onChange?()
    }

    /// Every source the viewer has: Plex's free channels unless turned off, each DVR on the server, each playlist.
    static func discoverSources(context: Context) async -> [any LiveChannelSource] {
        var sources: [any LiveChannelSource] = []
        if let api = context.api, let machine = context.machineIdentifier {
            do {
                for dvr in try await PlexDVR.list(api: api) {
                    sources.append(PlexDVRSource(api: api, dvr: dvr, machineIdentifier: machine, serverName: context.serverName ?? LiveTVCopy.yourServer))
                }
            } catch {
                MidgarLog.notice("The server lists no DVRs: \(error.localizedDescription)", category: .liveTV)
            }
        }
        sources += LivePlaylistStore.all().map { PlaylistChannelSource(playlist: $0) }
        if LiveTVPreferences.showsPlexChannels, !context.token.isEmpty { sources.append(PlexFreeChannelSource(token: context.token)) }
        return sources
    }

    /// Asks for the airings of `channelIDs` (the rows on screen) that are not loaded or are older than a quarter hour.
    package func loadPrograms(for channelIDs: [String]) {
        let now = Date()
        let wanted = channelIDs.filter { id in
            guard requested.contains(id) else { return true }
            return now.timeIntervalSince(requestedAt[id] ?? .distantPast) > 15 * 60
        }
        guard !wanted.isEmpty else { return }
        let byID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let window = DateInterval(start: now.addingTimeInterval(-3600), duration: (Self.guideHours + 1) * 3600)
        var bySource: [LiveSourceID: [LiveChannel]] = [:]
        for id in wanted {
            guard let channel = byID[id] else { continue }
            requested.insert(id)
            requestedAt[id] = now
            bySource[channel.source, default: []].append(channel)
        }
        for (sourceID, group) in bySource {
            guard let source = sources.first(where: { $0.id == sourceID }) else { continue }
            let key = "\(sourceID)|\(group.map(\.id).joined(separator: ","))"
            programTasks[key] = Task { [weak self] in
                let found = (try? await source.programs(for: group, in: window)) ?? [:]
                guard let self, !Task.isCancelled else { return }
                self.programTasks[key] = nil
                for channel in group { self.programs[channel.id] = found[channel.id] ?? [] }
                self.onPrograms?(Set(group.map(\.id)))
            }
        }
    }

    package func programs(of channelID: String) -> [LiveProgram] {
        programs[channelID] ?? []
    }

    package func nowAndNext(_ channelID: String, at date: Date = Date()) -> (now: LiveProgram?, next: LiveProgram?) {
        LiveGuideMath.nowAndNext(programs[channelID] ?? [], at: date)
    }

    package func channel(id: String) -> LiveChannel? {
        channels.first { $0.id == id }
    }

    /// The channel `offset` places from `channelID` in the visible list, wrapping around, for channel up and down.
    package func channel(from channelID: String, offset: Int) -> LiveChannel? {
        let list = visibleChannels.contains { $0.id == channelID } ? visibleChannels : channels
        guard !list.isEmpty, let index = list.firstIndex(where: { $0.id == channelID }) else { return list.first }
        let next = ((index + offset) % list.count + list.count) % list.count
        return list[next]
    }

    package func isFavorite(_ channelID: String) -> Bool {
        LiveTVPreferences.favorites.contains(channelID)
    }

    package func toggleFavorite(_ channelID: String) {
        var favorites = LiveTVPreferences.favorites
        if favorites.contains(channelID) {
            favorites.removeAll { $0 == channelID }
        } else {
            favorites.append(channelID)
        }
        LiveTVPreferences.favorites = favorites
        if filter == .favorites, favorites.isEmpty { filter = .all }
        onChange?()
    }

    /// Remembers that the viewer watched `channelID`, for Recent and for the channel the guide opens on.
    package func watched(_ channelID: String) {
        LiveTVPreferences.noteWatched(channelID)
    }

    /// The source a channel comes from, for recording.
    package func source(of channel: LiveChannel) -> (any LiveChannelSource)? {
        sources.first { $0.id == channel.source }
    }
}

/// What the viewer chose for Live TV, kept on the device. Channel ids carry no addresses, so nothing secret lands here.
package enum LiveTVPreferences {
    private static let favoritesKey = "liveTVFavorites"
    private static let recentKey = "liveTVRecent"
    private static let plexChannelsKey = "liveTVShowsPlexChannels"
    private static let filterKey = "liveTVFilter"
    private static let betaSeenKey = "liveTVBetaNoteSeen"
    private static let destinationKey = "liveTVShowsDestination"
    private static let recentLimit = 20

    package static var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: favoritesKey) }
    }

    package static var recentChannels: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(recentLimit)), forKey: recentKey) }
    }

    package static func noteWatched(_ channelID: String) {
        recentChannels = [channelID] + recentChannels.filter { $0 != channelID }
    }

    /// Whether Plex's free channels are in the guide.
    package static var showsPlexChannels: Bool {
        get { UserDefaults.standard.object(forKey: plexChannelsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: plexChannelsKey)
            Task { @MainActor in NotificationCenter.default.post(name: .liveSourcesChanged, object: nil) }
        }
    }

    /// Whether Live TV has its own tab (or sidebar entry).
    package static var showsDestination: Bool {
        get { UserDefaults.standard.object(forKey: destinationKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: destinationKey)
            Task { @MainActor in NotificationCenter.default.post(name: .liveDestinationChanged, object: nil) }
        }
    }

    /// Whether the viewer has read what the Beta tag means, so it stops drawing attention to itself.
    package static var hasSeenBetaNote: Bool {
        get { UserDefaults.standard.bool(forKey: betaSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: betaSeenKey) }
    }

    static var lastFilter: LiveTVGuide.Filter? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: filterKey) else { return nil }
            switch raw {
            case "all": return .all
            case "favorites": return .favorites
            case "recent": return .recent
            default:
                if raw.hasPrefix("group:") { return .group(String(raw.dropFirst(6))) }
                if raw.hasPrefix("source:") {
                    let parts = raw.dropFirst(7).split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let kind = LiveSourceKind(rawValue: String(parts[0])) else { return nil }
                    return .source(LiveSourceID(kind: kind, key: String(parts[1])))
                }
                return nil
            }
        }
        set {
            let raw: String? = switch newValue {
            case .all?: "all"
            case .favorites?: "favorites"
            case .recent?: "recent"
            case .group(let name)?: "group:\(name)"
            case .source(let id)?: "source:\(id.kind.rawValue):\(id.key)"
            case nil: nil
            }
            UserDefaults.standard.set(raw, forKey: filterKey)
        }
    }

    /// Forgets everything Live TV kept on the device: favourites, recents, cached playlists and guides. Playlists the viewer
    /// added stay; they are removed one by one.
    package static func reset() {
        for key in [favoritesKey, recentKey, filterKey] { UserDefaults.standard.removeObject(forKey: key) }
        PlaylistCache.forgetAll()
    }
}

extension Notification.Name {
    /// Posted on the main thread when Live TV's tab was turned on or off.
    package static let liveDestinationChanged = Notification.Name("crucible.liveDestinationChanged")
}
