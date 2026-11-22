import Foundation
import MidgarCore

/// Keeps each day of each channel's Plex guide for a while, so moving around the guide does not ask again, and asks for
/// several channels at once but never too many.
actor PlexGridCache {
    static let shared = PlexGridCache()
    private static let lifetime: TimeInterval = 30 * 60
    private static let concurrency = 6

    private var days: [String: (programs: [LiveProgram], at: Date)] = [:]

    func programs(for channels: [LiveChannel], in window: DateInterval, cachePrefix: String,
                  fetch: @escaping @Sendable (_ channel: LiveChannel, _ date: String) async throws -> [LiveProgram]) async -> [String: [LiveProgram]] {
        let dates = PlexLiveLenient.gridDates(covering: DateInterval(start: window.start.addingTimeInterval(-6 * 3600), end: window.end))
        var jobs: [(channel: LiveChannel, date: String, key: String)] = []
        var result: [String: [LiveProgram]] = [:]
        let now = Date()
        for channel in channels {
            for date in dates {
                let key = "\(cachePrefix)|\(channel.id)|\(date)"
                if let cached = days[key], now.timeIntervalSince(cached.at) < Self.lifetime {
                    result[channel.id, default: []].append(contentsOf: cached.programs)
                } else {
                    jobs.append((channel, date, key))
                }
            }
        }
        var fetched: [(key: String, channelID: String, programs: [LiveProgram])] = []
        await withTaskGroup(of: (String, String, [LiveProgram]?).self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    do {
                        return (job.key, job.channel.id, try await fetch(job.channel, job.date))
                    } catch {
                        if !(error is CancellationError) {
                            MidgarLog.error("Guide for \(job.channel.title) on \(job.date) failed: \(error.localizedDescription)", category: .liveTV)
                        }
                        return (job.key, job.channel.id, nil)
                    }
                }
            }
            for _ in 0..<Self.concurrency { enqueue() }
            while let (key, channelID, programs) = await group.next() {
                if let programs { fetched.append((key, channelID, programs)) }
                enqueue()
            }
        }
        for item in fetched {
            days[item.key] = (item.programs, now)
            result[item.channelID, default: []].append(contentsOf: item.programs)
        }
        if days.count > 4000 { days = days.filter { now.timeIntervalSince($0.value.at) < Self.lifetime } }
        return result.mapValues { LiveGuideMath.normalized($0, in: window) }
    }

    func forget(prefix: String) {
        days = days.filter { !$0.key.hasPrefix(prefix + "|") }
    }
}

/// Plex's free channels, which every Plex account can watch: Plex's own live TV service, its guide and its HLS streams.
package struct PlexFreeChannelSource: LiveChannelSource {
    package let id = LiveSourceID.plexFree
    package let records = false
    package var title: String { LiveTVCopy.plexFreeTitle }
    let token: String

    package init(token: String) {
        self.token = token
    }

    /// The account the channels are asked for: a Home profile's own plex.tv token while one is active.
    private var plexTVToken: String { HomeProfiles.activePlexTVToken ?? token }

    package func channels() async throws -> [LiveChannel] {
        async let genres = genreTitles()
        let body: PlexLiveContainer<PlexLiveChannelsBody> = try await APIClient.plexTVRequest(.liveTVChannels, token: plexTVToken)
        let names = await genres
        return (body.MediaContainer.Channel ?? []).compactMap { channel in
            guard !channel.hidden, let id = channel.id, let title = channel.title,
                  let part = channel.Media?.first(where: { $0.drm != true })?.Part?.first?.key else { return nil }
            return LiveChannel(id: "plex.\(id)", source: .plexFree, number: nil, title: title,
                               logo: channel.thumb.flatMap { PlexLiveLenient.url($0, base: PlexTVHost.liveTV) },
                               groups: (channel.genreRatingKeys ?? []).compactMap { names[$0] }, isHD: channel.isHd,
                               guideKey: channel.gridKey, stream: .plexFree(partKey: part), summary: channel.summary)
        }
    }

    /// The names of the genres Plex files its channels under, by their rating keys.
    private func genreTitles() async -> [String: String] {
        guard let root: PlexLiveProviderRoot = try? await APIClient.plexTVRequest(.liveTVProvider, token: plexTVToken) else { return [:] }
        var names: [String: String] = [:]
        for feature in root.MediaProvider?.Feature ?? [] {
            for filter in feature.GridChannelFilter ?? [] {
                if let key = filter.genreRatingKey, let title = filter.title { names[key] = title }
            }
        }
        return names
    }

    package func programs(for channels: [LiveChannel], in window: DateInterval) async throws -> [String: [LiveProgram]] {
        let token = plexTVToken
        return await PlexGridCache.shared.programs(for: channels.filter { $0.guideKey != nil }, in: window, cachePrefix: "plex") { channel, date in
            let body: PlexLiveContainer<PlexLiveGridBody> = try await APIClient.plexTVRequest(.liveTVGrid(channelGridKey: channel.guideKey ?? "", date: date), token: token)
            return (body.MediaContainer.Metadata ?? []).compactMap { $0.program(channelID: channel.id, imageBase: PlexTVHost.liveTV) }
        }
    }

    /// The HLS address of a free channel, carrying what Plex's service asks of a player in its query, since a player
    /// cannot add headers.
    package static func streamURL(partKey: String, token: String) -> URL? {
        var components = URLComponents(url: PlexTVHost.liveTV, resolvingAgainstBaseURL: false)
        components?.path = partKey
        components?.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: HomeProfiles.activePlexTVToken ?? token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexHeaders.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: "Crucible"),
            URLQueryItem(name: "X-Plex-Platform", value: AppPlatform.plexName),
            URLQueryItem(name: "X-Plex-Device-Name", value: AppPlatform.fallbackDeviceName),
        ]
        return components?.url
    }
}

/// A tuner the viewer's Plex server records with: its channels, the guide the server keeps for them, live viewing through
/// the server and recordings.
package struct PlexDVRSource: LiveChannelSource {
    package let id: LiveSourceID
    package let records = true
    package let title: String
    let api: APIClient
    let dvr: PlexDVR

    package init(api: APIClient, dvr: PlexDVR, machineIdentifier: String, serverName: String) {
        self.api = api
        self.dvr = dvr
        self.id = LiveSourceID(kind: .plexDVR, key: "\(machineIdentifier).\(dvr.key)")
        self.title = dvr.title.map { "\(serverName) · \($0)" } ?? serverName
    }

    package func channels() async throws -> [LiveChannel] {
        let body: PlexLiveContainer<PlexLiveChannelsBody> = try await api.request(.dvrChannels(provider: dvr.epgIdentifier))
        let base = await api.baseURL
        let enabled = dvr.enabledChannels
        return (body.MediaContainer.Channel ?? []).compactMap { channel in
            guard let identifier = channel.id, let title = channel.title else { return nil }
            if let enabled, !enabled.contains(identifier) { return nil }
            return LiveChannel(id: "dvr.\(dvr.key).\(identifier)", source: id, number: channel.vcn, title: title,
                               logo: channel.thumb.flatMap { PlexLiveLenient.url($0, base: base) }, groups: [], isHD: channel.isHd,
                               guideKey: channel.gridKey ?? identifier, stream: .plexDVR(dvrKey: dvr.key, channel: identifier),
                               summary: channel.callSign)
        }
        .sorted { LiveGuideMath.numberOrder($0.number, $1.number) }
    }

    package func programs(for channels: [LiveChannel], in window: DateInterval) async throws -> [String: [LiveProgram]] {
        let api = api
        let provider = dvr.epgIdentifier
        let base = await api.baseURL
        return await PlexGridCache.shared.programs(for: channels.filter { $0.guideKey != nil }, in: window, cachePrefix: id.description) { channel, date in
            let body: PlexLiveContainer<PlexLiveGridBody> = try await api.request(.dvrGrid(provider: provider, channelGridKey: channel.guideKey ?? "", date: date))
            return (body.MediaContainer.Metadata ?? []).compactMap { $0.program(channelID: channel.id, imageBase: base) }
        }
    }
}

/// A DVR as the server lists it.
package struct PlexDVR: Sendable, Hashable {
    package let key: String
    package let title: String?
    /// The EPG provider the server keeps this DVR's guide in (`tv.plex.providers.epg.cloud:<n>`).
    package let epgIdentifier: String
    /// The lineup channels the viewer mapped to a tuner, or nil when the server does not say.
    package let enabledChannels: Set<String>?

    package init(key: String, title: String?, epgIdentifier: String, enabledChannels: Set<String>?) {
        self.key = key
        self.title = title
        self.epgIdentifier = epgIdentifier
        self.enabledChannels = enabledChannels
    }

    /// The server's DVRs; an empty list when it has none, or when it refuses because the account may not use them.
    package static func list(api: APIClient) async throws -> [PlexDVR] {
        let body: PlexLiveContainer<PlexDVRListBody> = try await api.request(.dvrs)
        return (body.MediaContainer.Dvr ?? []).compactMap(\.dvr)
    }
}

struct PlexDVRListBody: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct DeviceEntry: Decodable, Sendable {
            struct MappingEntry: Decodable, Sendable {
                let channelKey: String?
                let lineupIdentifier: String?
                let enabled: Bool

                enum CodingKeys: String, CodingKey { case channelKey, lineupIdentifier, enabled }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    channelKey = PlexLiveLenient.string(container, .channelKey)
                    lineupIdentifier = PlexLiveLenient.string(container, .lineupIdentifier)
                    enabled = PlexLiveLenient.bool(container, .enabled)
                }
            }

            let ChannelMapping: [MappingEntry]?
            let model: String?
            let make: String?
        }

        let key: String?
        let uuid: String?
        let lineupTitle: String?
        let epgIdentifier: String?
        let Device: [DeviceEntry]?
        let ChannelMapping: [DeviceEntry.MappingEntry]?

        enum CodingKeys: String, CodingKey { case key, uuid, lineupTitle, epgIdentifier, Device, ChannelMapping }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = PlexLiveLenient.string(container, .key)
            uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
            lineupTitle = try? container.decodeIfPresent(String.self, forKey: .lineupTitle)
            epgIdentifier = try? container.decodeIfPresent(String.self, forKey: .epgIdentifier)
            Device = try? container.decodeIfPresent([DeviceEntry].self, forKey: .Device)
            ChannelMapping = try? container.decodeIfPresent([DeviceEntry.MappingEntry].self, forKey: .ChannelMapping)
        }

        /// The DVR, when it is one: an entry with a key whose uuid is no `device://` tuner.
        var dvr: PlexDVR? {
            guard let key, uuid?.hasPrefix("device://") != true else { return nil }
            let mappings = (Device ?? []).flatMap { $0.ChannelMapping ?? [] } + (ChannelMapping ?? [])
            let enabled = mappings.isEmpty ? nil : Set(mappings.filter(\.enabled).compactMap(\.channelKey))
            let tuner = Device?.first.flatMap { device in [device.make, device.model].compactMap { $0 }.joined(separator: " ") }
            return PlexDVR(key: key, title: lineupTitle ?? (tuner?.isEmpty == false ? tuner : nil),
                           epgIdentifier: epgIdentifier ?? "tv.plex.providers.epg.cloud:\(key)", enabledChannels: enabled)
        }
    }

    let Dvr: [Entry]?

    enum CodingKeys: String, CodingKey { case Dvr, DVR }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Dvr = (try? container.decodeIfPresent([Entry].self, forKey: .Dvr)) ?? (try? container.decodeIfPresent([Entry].self, forKey: .DVR))
    }
}
