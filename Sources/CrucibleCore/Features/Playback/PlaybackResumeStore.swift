import Foundation
import MidgarCore

/// Where the viewer was in one item, kept on the device so a process the system ended while the app
/// was away still knows, and what the server was last told.
package struct ResumePoint: Codable, Sendable, Equatable {
    package let server: String
    package let ratingKey: String
    package var positionSecs: Double
    package var durationSecs: Double
    package var savedAt: Date
    package var reportedSecs: Double?
    /// Whether the run finished the item: the playhead reached the credits or the end of the timeline. The
    /// server is told the end of the item for one of these, so an episode the viewer finished leaves
    /// Continue Watching even when the app never got to say so.
    package var finished: Bool

    package init(
        server: String,
        ratingKey: String,
        positionSecs: Double,
        durationSecs: Double,
        savedAt: Date,
        reportedSecs: Double? = nil,
        finished: Bool = false
    ) {
        self.server = server
        self.ratingKey = ratingKey
        self.positionSecs = positionSecs
        self.durationSecs = durationSecs
        self.savedAt = savedAt
        self.reportedSecs = reportedSecs
        self.finished = finished
    }

    private enum CodingKeys: String, CodingKey {
        case server, ratingKey, positionSecs, durationSecs, savedAt, reportedSecs, finished
    }

    /// Positions saved by a run that predates `finished` read as unfinished, not as a lost point.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        positionSecs = try container.decode(Double.self, forKey: .positionSecs)
        durationSecs = try container.decode(Double.self, forKey: .durationSecs)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        reportedSecs = try container.decodeIfPresent(Double.self, forKey: .reportedSecs)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
    }

    /// How far the server's copy may differ before the device's position is worth sending.
    package static let reportTolerance = 2.0

    /// How long a position stays worth restoring.
    package static let lifetime: TimeInterval = 7 * 24 * 3600

    /// True while the server has not confirmed (within a couple of seconds) the position kept here.
    package var needsReport: Bool {
        guard let reportedSecs else { return true }
        return abs(reportSecs - reportedSecs) > Self.reportTolerance
    }

    /// The timeline position the server is told: the end of the item for a run that finished it, which ends
    /// it in Continue Watching and counts it as watched whatever the server's completion rule is.
    package var reportSecs: Double {
        finished ? max(positionSecs, durationSecs) : positionSecs
    }

    fileprivate var storageKey: String { Self.storageKey(server: server, ratingKey: ratingKey) }

    fileprivate static func storageKey(server: String, ratingKey: String) -> String { "\(server)/\(ratingKey)" }

    package var isWatched: Bool {
        WatchedRule.isWatched(positionMs: Int(positionSecs * 1000), durationMs: Int(durationSecs * 1000))
    }
}

/// The positions of the items played most recently, in `UserDefaults` (tvOS keeps no other persistent
/// storage). Every playback writes here as it goes, so the last position survives a suspension, a
/// termination and a server that could not be reached when the app went away. An item the run finished
/// stays here too, marked finished, until the server confirms it: that report is what ends a finished
/// episode in Continue Watching when the app was killed before its last one left.
package struct PlaybackResumeStore: Sendable {
    private static let key = "playbackResumePoints"
    private static let capacity = 20
    private static let lock = NSLock()

    nonisolated(unsafe) private let defaults: UserDefaults

    package static let shared = PlaybackResumeStore()

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func point(server: String, ratingKey: String) -> ResumePoint? {
        load()[ResumePoint.storageKey(server: server, ratingKey: ratingKey)]
    }

    /// Keeps `positionSecs` as the position of `ratingKey`, finished when the run reached the credits or the
    /// end of the item. A finished point is kept until the server confirms it rather than dropped, so the
    /// next launch can still end the item; an unfinished one is dropped once the percentage says watched,
    /// which is what a server has already recorded by then.
    package func save(
        server: String,
        ratingKey: String,
        positionSecs: Double,
        durationSecs: Double,
        finished: Bool = false,
        now: Date = Date()
    ) {
        guard positionSecs.isFinite, positionSecs >= 0 else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var points = load()
        let key = ResumePoint.storageKey(server: server, ratingKey: ratingKey)
        var point = points[key] ?? ResumePoint(server: server, ratingKey: ratingKey, positionSecs: positionSecs, durationSecs: durationSecs, savedAt: now)
        point.positionSecs = positionSecs
        point.durationSecs = durationSecs
        point.savedAt = now
        point.finished = finished || point.isWatched
        points[key] = point
        store(points, now: now)
    }

    /// Notes that the server now holds `positionSecs` for `ratingKey`.
    package func recordReport(server: String, ratingKey: String, positionSecs: Double) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var points = load()
        let key = ResumePoint.storageKey(server: server, ratingKey: ratingKey)
        guard var point = points[key] else { return }
        point.reportedSecs = positionSecs
        points[key] = point
        store(points, now: nil)
    }

    /// The positions of `server` that it has not been told about, newest first, leaving out ones that are too old to matter.
    package func pendingReports(server: String, now: Date = Date()) -> [ResumePoint] {
        load().values
            .filter { $0.server == server && $0.needsReport && now.timeIntervalSince($0.savedAt) <= ResumePoint.lifetime }
            .sorted { $0.savedAt > $1.savedAt }
    }

    private func load() -> [String: ResumePoint] {
        guard let data = defaults.data(forKey: Self.key),
              let points = try? JSONDecoder().decode([String: ResumePoint].self, from: data) else { return [:] }
        return points
    }

    private func store(_ points: [String: ResumePoint], now: Date?) {
        var kept = points
        if let now {
            kept = kept.filter { now.timeIntervalSince($0.value.savedAt) <= ResumePoint.lifetime }
        }
        if kept.count > Self.capacity {
            let newest = kept.values.sorted { $0.savedAt > $1.savedAt }.prefix(Self.capacity)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.storageKey, $0) })
        }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Whether a position kept on the device should replace what the server holds.
package enum ResumeFlushRule {
    /// How far after the device's save the server may have seen the item before another client is assumed
    /// to have watched it since; the allowance covers the two clocks not agreeing.
    package static let clockSkewAllowance: TimeInterval = 120

    /// Only a position that differs from the server's offset, unless another client has watched the item
    /// since the device saved it: that one must not be rewound. An item the server already counts as
    /// watched is never written to, and a finished run is always worth sending: it is what ends the item.
    package static func shouldSend(
        point: ResumePoint,
        serverOffsetSecs: Double,
        serverViewedAt: Date?,
        serverWatched: Bool = false
    ) -> Bool {
        guard !serverWatched else { return false }
        if point.finished {
            return point.durationSecs <= 0 || serverOffsetSecs < point.durationSecs - ResumePoint.reportTolerance
        }
        guard point.positionSecs > 0 else { return false }
        if let serverViewedAt, serverViewedAt.timeIntervalSince(point.savedAt) > clockSkewAllowance { return false }
        return abs(point.positionSecs - serverOffsetSecs) > ResumePoint.reportTolerance
    }
}

/// Tells the server where a previous run of the app left the viewer, for every position it never
/// confirmed: the app was suspended before its last report could leave, or the system ended it.
package enum PlaybackResumeSync {
    package static let launchBudget: Duration = .seconds(3)

    package static func flush(api: APIClient, server: String, store: PlaybackResumeStore = .shared, within budget: Duration = launchBudget) async {
        let pending = store.pendingReports(server: server)
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for point in pending { await send(point, api: api, store: store) } }
            group.addTask { try? await Task.sleep(for: budget) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func send(_ point: ResumePoint, api: APIClient, store: PlaybackResumeStore) async {
        guard !Task.isCancelled else { return }
        do {
            let container = try await api.requestContainer(.metadata(ratingKey: point.ratingKey))
            let item = container.Metadata?.first
            let viewedAt = item?.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            guard ResumeFlushRule.shouldSend(
                point: point,
                serverOffsetSecs: item?.positionSecs ?? 0,
                serverViewedAt: viewedAt,
                serverWatched: item?.isWatched ?? false
            ) else {
                store.recordReport(server: point.server, ratingKey: point.ratingKey, positionSecs: point.reportSecs)
                return
            }
            try await api.requestVoid(.timeline(
                ratingKey: point.ratingKey,
                state: "stopped",
                timeMs: Int(point.reportSecs * 1000),
                durationMs: Int(point.durationSecs * 1000)
            ))
            store.recordReport(server: point.server, ratingKey: point.ratingKey, positionSecs: point.reportSecs)
            await api.invalidate(ratingKey: point.ratingKey)
            MidgarLog.notice("Reported the saved position of \(point.ratingKey) to the server: \(Int(point.reportSecs)) s finished=\(point.finished)", category: .playback)
        } catch {
            MidgarLog.error("Reporting the saved position of \(point.ratingKey) failed: \(error.localizedDescription)", category: .playback)
        }
    }
}
