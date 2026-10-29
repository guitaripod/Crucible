import Foundation
import CrucibleCore

/// One scored expectation about how the app moves between episodes and how it keeps what is watched and
/// unwatched in step. `check` answers nil when the app behaves the way the viewer expects, or a short
/// reason when it does not.
struct Probe: Sendable {
    enum Group: String, Sendable, CaseIterable {
        case flow = "FLOW"
        case watched = "WATCHED"
        case screen = "SCREEN"
        case resume = "RESUME"
    }

    let id: String
    let group: Group
    let title: String
    let check: @Sendable () async -> String?
}

enum Probes {
    static func all() -> [Probe] {
        [
            inSeason, finale, lastEver, movie, unreadableSeason, agreement, requestShape, selections, offlineResume, ordering,
            threshold, creditsFinished, noMarkers, retryAfterFinish, finishedReport, serverWatched,
            watchedPlaysFromStart, watchedRow, inProgressRow, allWatched, mostRecent,
            pendingIsFlushed, confirmedIsClean, staleIsDropped, noRewind, resumeStrategy,
        ]
    }

    // MARK: - Flow: one episode to the next

    /// The episode after the one playing, and what the offer says about it.
    private static let inSeason = Probe(id: "flow.in-season", group: .flow, title: "an episode mid-season offers the one after it") {
        let server = BenchServer()
        BenchShow.serve(on: server)
        let resolver = BenchShow.resolver(after: Fixtures.episode(season: 1, index: 1))
        guard let offer = try? await resolver.loadOffer(api: server.client, reason: .credits) else {
            return "no offer"
        }
        if offer.episode.id != Fixtures.episodeKey(season: 1, index: 2) { return "offered \(offer.episode.id)" }
        if offer.seasonRatingKey != Fixtures.seasonKeys[1]! { return "offered a different season" }
        if case .credits = offer.reason {} else { return "wrong reason" }
        if offer.autoplays != (Preferences.skipOutroMode == .automatic) { return "a credits offer does not follow Skip Outro" }
        return nil
    }

    /// The end of a season is not the end of the show: the next episode of the show is the first of the
    /// season after, and the player must offer it exactly as the show screen already does.
    private static let finale = Probe(id: "flow.finale", group: .flow, title: "a season finale continues into the next season") {
        let server = BenchServer()
        BenchShow.serve(on: server, watchedThrough: 3)
        let resolver = BenchShow.resolver(after: Fixtures.episode(season: 1, index: 3))
        guard let offer = try? await resolver.loadOffer(api: server.client, reason: .playbackEnded) else {
            return "no offer after the last episode of a season"
        }
        if offer.episode.id != Fixtures.episodeKey(season: 2, index: 1) {
            return "offered \(offer.episode.id)"
        }
        if offer.seasonRatingKey != Fixtures.seasonKeys[2]! { return "kept the old season" }
        return nil
    }

    /// The last episode of the last season has nothing after it.
    private static let lastEver = Probe(id: "flow.last-episode", group: .flow, title: "the last episode of a show offers nothing") {
        let server = BenchServer()
        BenchShow.serve(on: server)
        let resolver = BenchShow.resolver(after: Fixtures.episode(season: 2, index: 3))
        let offer = try? await resolver.loadOffer(api: server.client, reason: .playbackEnded)
        guard let offer else { return nil }
        return "offered \(offer.episode.id) after the last episode"
    }

    /// A movie never asks the server what comes next.
    private static let movie = Probe(id: "flow.movie", group: .flow, title: "a movie never looks for a next episode") {
        let server = BenchServer()
        BenchShow.serve(on: server)
        let movie = Fixtures.episode(season: 1, index: 1)
        let resolver = UpNextResolver(ratingKey: movie.id, isEpisode: false, seasonRatingKey: nil, markers: [])
        if let offer = try? await resolver.loadOffer(api: server.client, reason: .playbackEnded) {
            return "offered \(offer.episode.id) for a movie"
        }
        if !server.requestedPaths.isEmpty { return "asked the server: \(server.requestedPaths)" }
        return nil
    }

    /// A season the server will not answer for leaves no offer, not a crash.
    private static let unreadableSeason = Probe(id: "flow.unreadable-season", group: .flow, title: "a season that cannot be read leaves no offer") {
        let server = BenchServer()
        server.fail("/library/metadata/\(Fixtures.seasonKeys[1]!)/children")
        let resolver = BenchShow.resolver(after: Fixtures.episode(season: 1, index: 1))
        if let offer = try? await resolver.loadOffer(api: server.client, reason: .credits) {
            return "offered \(offer.episode.id) from a season that failed"
        }
        return nil
    }

    /// The player and the show screen have to agree: after a finale the card says "next season" and the
    /// Continue button points at the same episode.
    private static let agreement = Probe(id: "flow.agreement", group: .flow, title: "the player and the show screen offer the same next episode") {
        let server = BenchServer()
        BenchShow.serve(on: server, watchedThrough: 3)
        let episodes = Fixtures.allEpisodes(season1: 3)
        let screen = ShowDetailModel(
            show: Fixtures.show(viewed: 3),
            seasons: [Fixtures.season(1, watched: 3), Fixtures.season(2)],
            selectedSeasonKey: Fixtures.seasonKeys[2],
            episodes: Fixtures.seasonEpisodes(2),
            allEpisodes: episodes
        )
        let player = try? await BenchShow.resolver(after: Fixtures.episode(season: 1, index: 3))
            .loadOffer(api: server.client, reason: .playbackEnded)
        let screenNext = screen.upNext?.episode.id
        let playerNext = player?.episode.id
        guard screenNext == playerNext else {
            return "screen says \(screenNext ?? "nothing"), player says \(playerNext ?? "nothing")"
        }
        return nil
    }

    /// The offer builds a request that starts the next episode from its start, in its own season, with the
    /// streams the viewer chose on the episode before.
    private static let requestShape = Probe(id: "flow.request", group: .flow, title: "the offer starts the next episode from the beginning") {
        let offer = UpNextOffer(
            episode: Fixtures.episode(season: 1, index: 2),
            seasonRatingKey: Fixtures.seasonKeys[1]!,
            reason: .credits,
            autoplays: true
        )
        let request = offer.nextRequest(showRatingKey: Fixtures.showKey)
        if request.resumePosition != 0 { return "starts at \(request.resumePosition) s" }
        if request.seasonRatingKey != Fixtures.seasonKeys[1]! { return "lost the season" }
        if request.showRatingKey != Fixtures.showKey { return "lost the show" }
        if request.metadata?.episodeNumber != 2 { return "lost the episode number" }
        return nil
    }

    /// What the viewer picked to listen to and read on this episode stays picked on the next one.
    private static let selections = Probe(id: "flow.selections", group: .flow, title: "the next episode keeps the viewer's subtitle and audio") {
        let offer = UpNextOffer(
            episode: Fixtures.episode(season: 1, index: 2),
            seasonRatingKey: Fixtures.seasonKeys[1]!,
            reason: .credits,
            autoplays: true
        )
        let request = offer.nextRequest(showRatingKey: Fixtures.showKey, selectedSubtitleId: 13, selectedAudioStreamId: 11)
        if request.selectedSubtitleId != 13 { return "lost the subtitle pick" }
        if request.selectedAudioStreamId != 11 { return "lost the audio pick" }
        return nil
    }

    /// A downloaded next episode starts where the viewer left the download, not at zero.
    private static let offlineResume = Probe(id: "flow.offline", group: .flow, title: "a downloaded next episode resumes where it was left") {
        let source = OfflinePlaybackSource(
            fileURL: URL(string: "http://127.0.0.1:1/next.m3u8")!,
            markers: [],
            durationSecs: 2_400,
            resumeSecs: 600
        )
        let offer = UpNextOffer(
            episode: Fixtures.episode(season: 1, index: 2),
            seasonRatingKey: Fixtures.seasonKeys[1]!,
            reason: .credits,
            autoplays: true
        )
        let request = offer.nextRequest(showRatingKey: Fixtures.showKey, offline: source)
        if request.resumePosition != 600 { return "starts at \(request.resumePosition) s" }
        if request.offline?.fileURL != source.fileURL { return "lost the download" }
        return nil
    }

    /// The next episode is decided by the episodes' own order, not by whatever order the server happened
    /// to return them in: a list in the wrong order must not skip an episode.
    private static let ordering = Probe(id: "flow.order", group: .flow, title: "the next episode follows episode order, not list order") {
        let server = BenchServer()
        let shuffled = [
            Fixtures.episode(season: 1, index: 1),
            Fixtures.episode(season: 1, index: 3),
            Fixtures.episode(season: 1, index: 2),
        ]
        server.reply("/library/metadata/\(Fixtures.seasonKeys[1]!)/children", items: shuffled)
        let resolver = BenchShow.resolver(after: Fixtures.episode(season: 1, index: 1))
        guard let offer = try? await resolver.loadOffer(api: server.client, reason: .credits) else {
            return "no offer"
        }
        if offer.episode.id != Fixtures.episodeKey(season: 1, index: 2) { return "skipped to \(offer.episode.id)" }
        return nil
    }

    // MARK: - Watched: what counts as finished and what the server is told

    private static let threshold = Probe(id: "watched.threshold", group: .watched, title: "past the threshold counts as watched, before it does not") {
        let duration = 2_400.0
        if !WatchedRule.isWatched(positionMs: Int(2_208 * 1000), durationMs: Int(duration * 1000)) {
            return "92 percent is not watched"
        }
        if WatchedRule.isWatched(positionMs: Int(2_200 * 1000), durationMs: Int(duration * 1000)) {
            return "91.7 percent is watched"
        }
        return nil
    }

    /// An episode stopped at the credits is one the viewer finished, whichever percentage of the timeline
    /// the credits begin at; the server itself counts a credits marker as the end (Plex's default
    /// completion behaviour is the earliest of the credits marker and the percentage).
    private static let creditsFinished = Probe(id: "watched.credits", group: .watched, title: "stopping at the credits counts as finished") {
        let duration = 2_400.0
        let creditsStart = 2_100.0
        guard FinishedProbe.isFinished(positionSecs: 2_110, durationSecs: duration, creditsStartSecs: creditsStart) else {
            return "87.9 percent at the credits is not finished"
        }
        return nil
    }

    /// Without credits markers the percentage still decides.
    private static let noMarkers = Probe(id: "watched.no-markers", group: .watched, title: "without credits markers the percentage still decides") {
        guard !FinishedProbe.isFinished(positionSecs: 2_200, durationSecs: 2_400, creditsStartSecs: nil) else {
            return "91.7 percent counts as finished without markers"
        }
        return nil
    }

    /// A finished item must leave something behind that can still be told to the server: the final
    /// "stopped" report is the only thing that ends a run in Continue Watching, and the app may be killed
    /// before it leaves.
    private static let retryAfterFinish = Probe(id: "watched.retry", group: .watched, title: "a finished item keeps a report to retry") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        store.save(server: "s", ratingKey: "e1", positionSecs: 2_304, durationSecs: 2_400)
        guard store.pendingReports(server: "s").contains(where: { $0.ratingKey == "e1" }) else {
            return "nothing left to tell the server about a finished episode"
        }
        return nil
    }

    /// The retried report carries the end of the item, which is what ends it in Continue Watching and
    /// counts it as watched whatever the server's completion rule is.
    private static let finishedReport = Probe(id: "watched.report-end", group: .watched, title: "a finished item is reported at its very end") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        store.save(server: "s", ratingKey: "e1", positionSecs: 2_110, durationSecs: 2_400, finished: true)
        guard let point = store.pendingReports(server: "s").first(where: { $0.ratingKey == "e1" }) else {
            return "no report left"
        }
        if point.reportSecs != 2_400 { return "reports \(Int(point.reportSecs)) s, not the end" }
        if ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 2_400, serverViewedAt: nil) {
            return "sends the end again over an item already at its end"
        }
        return nil
    }

    /// A finished run is not written over an item the server already counts as watched.
    private static let serverWatched = Probe(id: "watched.server", group: .watched, title: "a position never rewinds an item the server counts as watched") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        store.save(server: "s", ratingKey: "e1", positionSecs: 600, durationSecs: 2_400)
        guard let point = store.pendingReports(server: "s").first else { return "no point saved" }
        if ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 0, serverViewedAt: nil, serverWatched: true) {
            return "writes over an item the server counts as watched"
        }
        return nil
    }

    // MARK: - Screen: what a watched episode offers

    /// A watched episode plays from the beginning, whatever offset the server left on it.
    private static let watchedPlaysFromStart = Probe(id: "screen.start", group: .screen, title: "a watched episode plays from the beginning") {
        let watched = Fixtures.episode(season: 1, index: 1, watched: true, offsetSecs: 2_110)
        let model = MovieDetailModel(item: watched)
        if model.resumePosition(offlineResumeSecs: nil) != 0 {
            return "resumes at \(Int(model.resumePosition(offlineResumeSecs: nil))) s"
        }
        return nil
    }

    /// And its row says Play, not Resume.
    private static let watchedRow = Probe(id: "screen.row", group: .screen, title: "a watched episode's row offers Play, not Resume") {
        let watched = Fixtures.episode(season: 1, index: 1, watched: true, offsetSecs: 2_110)
        let status = EpisodeStatus(episode: watched, isUpNext: false)
        if status.playTitle != "Play" { return "row says \(status.playTitle)" }
        if status.canPlayFromBeginning { return "row offers to play from the beginning" }
        if status.marker != .watched { return "row is marked \(status.marker)" }
        return nil
    }

    /// An in-progress episode's row resumes, and the up-next row is marked as such.
    private static let inProgressRow = Probe(id: "screen.progress", group: .screen, title: "an in-progress episode resumes and the up-next row is marked") {
        let part = Fixtures.episode(season: 1, index: 1, offsetSecs: 600)
        let status = EpisodeStatus(episode: part, isUpNext: true)
        if status.playTitle != "Resume" { return "row says \(status.playTitle)" }
        if status.marker != .inProgress { return "row is marked \(status.marker)" }
        let next = EpisodeStatus(episode: Fixtures.episode(season: 1, index: 2), isUpNext: true)
        if next.marker != .upNext { return "up-next row is marked \(next.marker)" }
        return nil
    }

    /// Everything watched offers the first episode to start over rather than dead-ending.
    private static let allWatched = Probe(id: "screen.all-watched", group: .screen, title: "a finished show offers its first episode again") {
        let episodes = Fixtures.allEpisodes(season1: 3, season2: 3)
        let model = ShowDetailModel(
            show: Fixtures.show(viewed: 6),
            seasons: [Fixtures.season(1, watched: 3), Fixtures.season(2, watched: 3)],
            selectedSeasonKey: Fixtures.seasonKeys[1],
            episodes: Fixtures.seasonEpisodes(1, watchedThrough: 3),
            allEpisodes: episodes
        )
        guard let upNext = model.upNext else { return "no next episode" }
        if upNext.episode.id != Fixtures.episodeKey(season: 1, index: 1) { return "offered \(upNext.episode.id)" }
        if upNext.kind != .start { return "kind is \(upNext.kind)" }
        if !model.isWatched { return "the show does not count as watched" }
        return nil
    }

    /// The show's Continue follows what the viewer watched last, so it matches the server's own Continue
    /// Watching row instead of pointing at an episode abandoned days ago.
    private static let mostRecent = Probe(id: "screen.recent", group: .screen, title: "the show screen follows the most recent watch") {
        let episodes = [
            Fixtures.episode(season: 1, index: 1, watched: true, lastViewedAt: 1_000),
            Fixtures.episode(season: 1, index: 2, offsetSecs: 600, lastViewedAt: 2_000),
            Fixtures.episode(season: 1, index: 3, watched: true, lastViewedAt: 9_000),
            Fixtures.episode(season: 1, index: 4),
        ]
        let model = ShowDetailModel(
            show: Fixtures.show(viewed: 2),
            seasons: [Fixtures.season(1, watched: 2)],
            selectedSeasonKey: Fixtures.seasonKeys[1],
            episodes: episodes,
            allEpisodes: episodes
        )
        guard let upNext = model.upNext else { return "no next episode" }
        if upNext.episode.id != Fixtures.episodeKey(season: 1, index: 4) { return "offers \(upNext.episode.id)" }
        if upNext.kind != .next { return "kind is \(upNext.kind)" }
        return nil
    }

    // MARK: - Resume: the positions the device tells the server about

    private static let pendingIsFlushed = Probe(id: "resume.pending", group: .resume, title: "an unreported position is kept for the next launch") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        store.save(server: "s", ratingKey: "e1", positionSecs: 600, durationSecs: 2_400)
        guard store.pendingReports(server: "s").contains(where: { $0.ratingKey == "e1" }) else {
            return "a position the server never saw was forgotten"
        }
        return nil
    }

    private static let confirmedIsClean = Probe(id: "resume.confirmed", group: .resume, title: "a position the server confirmed is not sent again") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        store.save(server: "s", ratingKey: "e1", positionSecs: 600, durationSecs: 2_400)
        store.recordReport(server: "s", ratingKey: "e1", positionSecs: 600)
        if store.pendingReports(server: "s").contains(where: { $0.ratingKey == "e1" }) {
            return "a confirmed position is still queued"
        }
        return nil
    }

    private static let staleIsDropped = Probe(id: "resume.stale", group: .resume, title: "a position older than a week is not sent") {
        let store = PlaybackResumeStore(defaults: scratchDefaults())
        let long = Date().addingTimeInterval(-8 * 24 * 3600)
        store.save(server: "s", ratingKey: "e1", positionSecs: 600, durationSecs: 2_400, now: long)
        if store.pendingReports(server: "s").contains(where: { $0.ratingKey == "e1" }) {
            return "an eight-day-old position is still queued"
        }
        return nil
    }

    /// Another client that watched the item since the device saved must not be rewound.
    private static let noRewind = Probe(id: "resume.no-rewind", group: .resume, title: "a newer watch from another client is never rewound") {
        let saved = Date().addingTimeInterval(-1_800)
        let point = ResumePoint(server: "s", ratingKey: "e1", positionSecs: 600, durationSecs: 2_400, savedAt: saved)
        let viewedAfter = saved.addingTimeInterval(600)
        if ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 1_800, serverViewedAt: viewedAfter) {
            return "the device would rewind a newer watch"
        }
        if !ResumeFlushRule.shouldSend(point: point, serverOffsetSecs: 0, serverViewedAt: nil) {
            return "a position the server never saw is not sent"
        }
        return nil
    }

    /// A transcode resumes through its offset and is never seeked again; a direct-play file seeks.
    private static let resumeStrategy = Probe(id: "resume.strategy", group: .resume, title: "a transcode resumes through its offset, a file seeks") {
        if ResumeStrategy.make(resumePosition: 600, isDirectPlay: false, isOffline: false) != .none {
            return "a transcode would seek"
        }
        if ResumeStrategy.streamOffset(resumePosition: 600.7, isDirectPlay: false) != 600 {
            return "the transcode offset is not the whole second"
        }
        if ResumeStrategy.make(resumePosition: 600, isDirectPlay: true, isOffline: false) != .seekExact(600) {
            return "a direct-play file would not seek"
        }
        if ResumeStrategy.make(resumePosition: 600, isDirectPlay: true, isOffline: true) != .seekWhenReady(600) {
            return "an offline item would not wait for its item"
        }
        return nil
    }
}

/// A `UserDefaults` suite of this run's own, so the benchmark never reads or writes the app's positions.
private func scratchDefaults() -> UserDefaults {
    let name = "crucible-bench-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
