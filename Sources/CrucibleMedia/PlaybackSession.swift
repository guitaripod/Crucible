import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

/// One playback of one item, from stream resolution to teardown, independent of any screen.
///
/// A surface calls `prepare()` (or relies on the offline stream a downloaded item starts with),
/// decides whether it can present, then either `begin()`s playback and hosts the returned player or
/// `discard()`s the stream. While it runs the session reports through `events`; `stop()` ends it.
/// Resume follows `ResumeStrategy`: a transcode starts at the stored position through its URL offset
/// and is never seeked again. Where the viewer is comes from a `PlayheadTracker`, never straight from
/// the player's clock, and is kept on the device (`PlaybackResumeStore`) as playback goes, so a
/// suspension, a sleeping Apple TV or a terminated app still leaves the true position behind.
///
/// The session also heals itself. A heartbeat notices any absence (`AwayDetector`), even one no
/// lifecycle notification announced, and a transcode the server may have reaped (`TranscodeLiveness`:
/// pings, segment loads and the item's error log) is rebuilt under a new server session at the true
/// position before it plays on. An item that ends short of its credits is not taken for the end of the
/// episode (`ItemEndRule`). After a break the player backs up a little (`BreakRule`).
///
/// A session plays exactly once: after `stop()` or `discard()` it is spent (`prepare()` throws
/// `CancellationError`, `begin()` returns nil), so a retry or a second presentation makes a new session.
@MainActor
package final class PlaybackSession {
    package let request: PlaybackRequest
    package let events: AsyncStream<PlaybackEvent>
    package internal(set) var player: AVPlayer?
    package internal(set) var stream: ResolvedStream?
    /// What is added to the player's clock to place it on the item's timeline.
    package var streamOffset: Double { tracker.streamOffset }
    /// Where the stream on the player begins on the item's timeline: zero for a file, the offset a transcode started at.
    var streamStart: Double { tracker.streamStart }
    package internal(set) var selectedSubtitleId: Int?
    package internal(set) var selectedAudioStreamId: Int?

    /// Called with every `AVPlayerItem` the session puts in the player (the first, a restarted
    /// transcode, a fallback, a re-resolved stream) so the surface can attach item-level state
    /// such as external metadata or a content proposal. The session's `streamOffset` is its best
    /// knowledge when it runs; a transcode whose clock turns out to read otherwise sends `.clockRemapped`.
    package var configureItem: (@MainActor (AVPlayerItem) -> Void)?

    let api: APIClient
    let tracker: PlayheadTracker
    let resumeStore: PlaybackResumeStore
    let serverID: String
    let continuation: AsyncStream<PlaybackEvent>.Continuation
    var reporter: PlaybackReporter?
    /// The connected integrations following this playback (Trakt's scrobbler), told of each play, pause and the end.
    var watchers: [PlaybackWatching] = []
    var remoteCommands: PlaybackRemoteCommands?
    var itemWatcher: PlayerItemWatcher?
    var playheadObserver: Any?
    var interruptionObserver: (any NSObjectProtocol)?
    var restartItemObserver: NSKeyValueObservation?
    var offlineResumeObserver: NSKeyValueObservation?
    var markerTracker = MarkerTracker(markers: [])
    var upNext: UpNextResolver
    var failurePolicy = PlaybackFailurePolicy()
    var lastPlayhead: Double = 0
    var lastSavedPosition: Double?
    var isSuspended = false
    var isRecovering = false
    var wasPlayingAtLastTick = false
    var resumesAfterReturn = false
    var returnedAt: Date?
    var isRestarting = false
    var pendingRestart: PendingRestart?
    var restartResumesPlayback = true
    var awayDetector = AwayDetector()
    var awaySince: ContinuousClock.Instant?
    var positionAtLastBeat: Double?
    var settlingUntil: ContinuousClock.Instant?
    var staleClock: Double?
    var selectionCarry: MediaSelectionCarry?
    var pausedSince: ContinuousClock.Instant?
    var liveness: TranscodeLiveness?
    var heals = HealBudget()
    var hasGivenUp = false
    var prematureEndPosition: Double?
    /// Whether the surface is in the foreground; set by the surface from its lifecycle notifications.
    package var isInForeground = true
    var heartbeatTask: Task<Void, Never>?
    var rateObserver: NSKeyValueObservation?
    #if DEBUG
    var debugClockShift: Duration = .zero
    #endif
    var upNextGate = UpNextLookupGate()
    /// The last thing a lookup for the next episode found, which tells a finished episode that closed a season or the
    /// whole show apart from one in the middle of a run.
    var upNextOutcome: UpNextLookup?
    /// The sleep timer the viewer set, if any.
    package internal(set) var sleepTimer: SleepTimer?
    var volumeBeforeFade: Float?
    let installsRemoteCommands: Bool
    var isChangingStreams = false
    /// The latest audio and subtitle the viewer asked for while a change was still resolving; the running change takes it up
    /// when it finishes, so no choice is lost.
    var pendingStreamChoice: StreamChoice?
    var pendingRebuild = false
    /// Whether the viewer turned subtitles off (in a menu, the system controls or Siri), as opposed to none ever being picked: only
    /// that is carried to the next episode and remembered for the show, so a file whose server picks a subtitle (such as forced
    /// subtitles for a foreign language) still gets it.
    var subtitlesTurnedOff = false
    var subtitleSyncTask: Task<Void, Never>?
    var selectionUpdateTask: Task<Void, Never>?
    var subtitleObserver: (any NSObjectProtocol)?
    var subtitleGroup: AVMediaSelectionGroup?
    var subtitleItem: ObjectIdentifier?
    /// The subtitle option the app last selected on the item, so the change notice for its own selection is not taken for the
    /// viewer's.
    var appliedSubtitleOption: AVMediaSelectionOption?
    /// The choice a running change is resolving, which a pick made meanwhile is merged with.
    var resolvingStreamChoice: StreamChoice?
    var isStopped = false
    var isUpNextVisible = false
    var isUndoVisible = false
    /// Set when a surface puts a prepared player on screen and asks it to start while the resume seek it
    /// needs is still on its way: the seek plays it the moment it lands, so the item never shows a moment of
    /// its start first.
    var playsAfterResume = false
    var pingTask: Task<Void, Never>?
    var undoTask: Task<Void, Never>?
    var upNextTask: Task<Void, Never>?
    var fallbackTask: Task<Void, Never>?
    var routeCheckTask: Task<Void, Never>?
    var rebuildTask: Task<Void, Never>?
    var hasCheckedRouteAfterFailure = false
    var routeObservation: UUID?

    /// `installsRemoteCommands` is false for a player whose system UI already owns the remote
    /// commands (the tvOS player): a second set of handlers would double-toggle play and pause.
    package init(
        api: APIClient,
        request: PlaybackRequest,
        installsRemoteCommands: Bool = true,
        resumeStore: PlaybackResumeStore = .shared
    ) {
        self.api = api
        self.resumeStore = resumeStore
        serverID = ServerBootstrap.savedMachineIdentifier ?? "unknown"
        tracker = PlayheadTracker(server: serverID)
        self.request = request
        self.installsRemoteCommands = installsRemoteCommands
        CellularWatch.start()
        selectedSubtitleId = request.selectedSubtitleId
        selectedAudioStreamId = request.selectedAudioStreamId
        let pair = AsyncStream.makeStream(of: PlaybackEvent.self)
        events = pair.stream
        continuation = pair.continuation
        upNext = UpNextResolver(
            ratingKey: request.ratingKey,
            isEpisode: request.isEpisode,
            seasonRatingKey: request.seasonRatingKey,
            queue: request.queue,
            markers: []
        )
        if let offline = request.offline {
            stream = ResolvedStream(
                url: offline.fileURL,
                isDirectPlay: true,
                sessionId: "offline",
                subtitles: [],
                audioTracks: [],
                markers: offline.markers
            )
        }
    }

    /// The item's timeline position of the playhead, or nil before playback starts.
    package var absolutePosition: Double? {
        guard let player else { return nil }
        return tracker.position(playerSeconds: player.currentTime().seconds, isReady: isItemReady)
    }

    var isItemReady: Bool {
        player?.currentItem?.status == .readyToPlay
    }

    /// The continuous clock the session measures absences and pauses with.
    func now() -> ContinuousClock.Instant {
        #if DEBUG
        ContinuousClock.now.advanced(by: debugClockShift)
        #else
        ContinuousClock.now
        #endif
    }

    #if DEBUG
    /// Moves the session's clock forward as if the device had slept for `duration` without telling the app.
    package func debugAdvanceClock(by duration: Duration) {
        debugClockShift += duration
    }
    #endif

    /// The position to act on when the player's clock cannot be trusted right now.
    var bestKnownPosition: Double {
        tracker.heldPosition ?? absolutePosition ?? tracker.lastGoodPosition ?? lastPlayhead + streamOffset
    }

    /// Whether the playhead has really reached the credits or the end of the item, the only places an Up
    /// Next card belongs. An offline item and a direct-play file always qualify: their clock is the file's own.
    package var isAtCreditsOrEnd: Bool {
        guard let stream, !stream.isDirectPlay, request.offline == nil else { return true }
        return ItemEndRule.isGenuineEnd(absolute: bestKnownPosition, duration: request.durationSecs, creditsStart: creditsStartSecs)
    }

    /// Resolves the stream to play. A cancelled caller gets `CancellationError` and any transcode the
    /// server already started is stopped. A downloaded item is ready without a network round trip.
    package func prepare() async throws -> ResolvedStream {
        if isStopped { throw CancellationError() }
        if let stream { return stream }
        let languages = startingLanguages
        let resolved = try await StreamResolver.resolve(
            api: api,
            ratingKey: request.ratingKey,
            startSecs: request.transcodeStartSecs,
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioStreamId,
            languages: languages,
            honorsServerSelection: languages == nil,
            captionLanguage: SystemCaptions.alwaysOnLanguage
        )
        guard !Task.isCancelled else {
            discardTranscode(of: resolved)
            throw CancellationError()
        }
        stream = resolved
        selectedSubtitleId = resolved.chosenSubtitleId
        selectedAudioStreamId = resolved.chosenAudioStreamId
        subtitlesTurnedOff = resolved.chosenSubtitleId == nil && languages?.subtitlesOff == true
        return resolved
    }

    /// The languages a fresh start begins in when no stream was chosen by id: the episode before's, else the ones last
    /// chosen on the show.
    private var startingLanguages: TrackLanguages? {
        request.trackLanguages ?? (request.isEpisode ? ShowTrackMemory.languages(forShow: request.showRatingKey, server: serverID) : nil)
    }

    /// The audio and subtitle playing now, as languages the next episode can find among its own streams.
    package var trackLanguages: TrackLanguages? {
        guard let stream else { return request.trackLanguages }
        return TrackLanguages(
            subtitleId: selectedSubtitleId,
            audioStreamId: selectedAudioStreamId,
            subtitles: stream.subtitles,
            audioTracks: stream.audioTracks,
            subtitlesOff: subtitlesTurnedOff
        )
    }

    /// Gives up on a prepared stream that will not be played and ends the session.
    package func discard() {
        guard player == nil, !isStopped else { return }
        isStopped = true
        if let stream { discardTranscode(of: stream) }
        stream = nil
        continuation.finish()
    }

    /// Creates the player and starts playback at the resume position. The caller hosts the returned
    /// player in its own surface; the session keeps driving it until `stop()`. Returns nil when there
    /// is no prepared stream, playback already began, or the session is spent. `autoplay` false leaves the
    /// player paused: a surface that swaps this player in for the episode before it starts it itself once
    /// the picture is there.
    package func begin(autoplay: Bool = true) -> AVPlayer? {
        guard let stream, player == nil, !isStopped else { return nil }
        let start = ResumeStrategy.streamStart(resumePosition: request.resumePosition, isDirectPlay: stream.isDirectPlay)
        tracker.beginStream(start: start, isTranscode: !stream.isDirectPlay)
        tracker.moved(to: request.resumePosition)
        if !stream.isDirectPlay { lastPlayhead = start - streamOffset }
        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        self.player = player
        if request.offline == nil {
            routeObservation = ServerRouteMonitor.shared.observe { [weak self] move in self?.routeMoved(move) }
        }
        if let item = player.currentItem { configureItem?(item) }
        if !request.isExtra {
            reporter = PlaybackReporter(
                api: api,
                ratingKey: request.ratingKey,
                durationMs: Int(request.durationSecs * 1000),
                player: player,
                tracker: tracker,
                resumeStore: resumeStore,
                server: serverID
            )
            watchers = Integrations.playbackWatchers(for: playbackSubject)
        }

        markerTracker = MarkerTracker(segments: stream.segments)
        upNext = UpNextResolver(
            ratingKey: request.ratingKey,
            isEpisode: request.isEpisode,
            seasonRatingKey: request.seasonRatingKey,
            showRatingKey: request.showRatingKey,
            queue: request.queue,
            markers: stream.markers
        )
        if installsRemoteCommands { configureRemoteCommands() }
        if !stream.isDirectPlay {
            liveness = TranscodeLiveness(confirmedAt: now())
            startPing(session: stream.sessionId)
        }
        observeInterruptions()
        observePlayhead(of: player)
        observeRate(of: player)
        startHeartbeat()
        watchCurrentItem()
        startPlayback(player: player, stream: stream, resumePosition: request.resumePosition, autoplay: autoplay)
        return player
    }

    /// Ends playback: stops the transcode, reports the final position, drops cached metadata of the
    /// item, its season and its show, and releases the player. An item the viewer finished is reported at
    /// its very end, which is what ends it in Continue Watching and counts it as watched on a server whose
    /// completion rule does not happen to be the one this item's credits cross. Returns the playhead at the
    /// moment of the stop so a caller can persist it.
    @discardableResult
    package func stop() async -> Double? {
        guard !isStopped else { return nil }
        isStopped = true
        let finalPosition = finalPlayhead()
        let finished = finalPosition.map { hasFinished(at: $0) } ?? false
        remoteCommands?.tearDown()
        remoteCommands = nil
        cancelBackgroundWork()
        stopFollowingSubtitles()
        itemWatcher?.invalidate()
        itemWatcher = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil

        if let finalPosition {
            let date = Date()
            watchers.forEach { $0.playback(.stopped(position: finalPosition, finished: finished, at: date)) }
        }
        watchers = []
        await invalidateCaches()
        await reporter?.stop(positionSecs: Self.reportPosition(for: finalPosition, finished: finished, duration: request.durationSecs))
        reporter = nil
        if player != nil { keepPosition(finalPosition, finished: finished) }
        if finished { recordFinish() }
        removePlayheadObservers()
        await stopTranscodeIfNeeded()

        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        continuation.finish()
        return finalPosition
    }

    /// What the integrations are told this playback is of.
    private var playbackSubject: PlaybackSubject {
        PlaybackSubject(
            ratingKey: request.ratingKey,
            mediaType: request.mediaType,
            showRatingKey: request.showRatingKey,
            title: request.metadata?.title ?? "",
            showTitle: request.metadata?.showName,
            seasonNumber: request.metadata?.seasonNumber,
            episodeNumber: request.metadata?.episodeNumber,
            durationSecs: request.durationSecs,
            server: serverID,
            api: api
        )
    }

    /// Notes a finished movie or episode in the ledger that asks the viewer to rate what they watched. An episode closed
    /// its season when the next one belongs to another season, and closed the show when there was nothing next.
    private func recordFinish() {
        guard !request.isExtra, let metadata = request.metadata else { return }
        let kind: FinishedTitle.Kind
        switch request.mediaType {
        case "movie": kind = .movie
        case "episode": kind = .episode
        default: return
        }
        var endedShow = false
        var endedSeason = false
        if kind == .episode {
            switch upNextOutcome {
            case .offer(let offer):
                endedSeason = request.queue == nil && offer.episode.parentIndex != nil && offer.episode.parentIndex != metadata.seasonNumber
            case .nothingNext:
                endedShow = request.queue == nil
            case .failed, nil:
                break
            }
        }
        FinishedTitlesLedger.shared.record(FinishedTitle(
            ratingKey: request.ratingKey,
            kind: kind,
            title: metadata.title,
            showTitle: metadata.showName,
            showRatingKey: request.showRatingKey,
            seasonNumber: metadata.seasonNumber,
            episodeNumber: metadata.episodeNumber,
            posterPath: metadata.posterPath,
            showPosterPath: metadata.showPosterPath,
            finishedAt: Date(),
            endedShow: endedShow,
            endedSeason: endedSeason,
            librarySectionID: metadata.librarySectionID
        ), server: serverID == "unknown" ? nil : serverID)
    }

    /// Whether the viewer finished the item at `position`: the playhead reached the credits, or the
    /// percentage, or the end of the timeline. The credits are the rule Plex itself finishes items by, so an
    /// episode left in the middle of long end credits is finished all the same.
    package func hasFinished(at position: Double) -> Bool {
        WatchedRule.isFinished(
            positionSecs: position,
            durationSecs: request.durationSecs,
            creditsStartSecs: creditsStartSecs
        )
    }

    /// Whether playback is at the end of the item right now.
    package var isFinishedNow: Bool { hasFinished(at: bestKnownPosition) }

    /// What the server is told for a run that ends here: the very end of the item for a finished one, so
    /// the item leaves Continue Watching whatever the server's completion rule is, and the playhead otherwise.
    private static func reportPosition(for position: Double?, finished: Bool, duration: Double) -> Double? {
        guard finished else { return position }
        return max(position ?? 0, duration > 0 ? duration : position ?? 0)
    }

    func emit(_ event: PlaybackEvent) {
        guard !isStopped else { return }
        continuation.yield(event)
    }

    func discardTranscode(of stream: ResolvedStream) {
        guard !stream.isDirectPlay else { return }
        discardTranscode(session: stream.sessionId)
    }

    func discardTranscode(session: String) {
        Task { [api] in
            try? await api.requestVoid(.stopTranscode(session: session))
        }
    }

    private func finalPlayhead() -> Double? {
        absolutePosition ?? StreamPosition.absolute(playerSeconds: lastPlayhead, streamOffset: streamOffset)
    }

    private func cancelBackgroundWork() {
        for task in [pingTask, undoTask, upNextTask, fallbackTask, heartbeatTask, routeCheckTask, rebuildTask, subtitleSyncTask] { task?.cancel() }
        subtitleSyncTask = nil
        routeCheckTask = nil
        rebuildTask = nil
        if let routeObservation { ServerRouteMonitor.shared.stopObserving(routeObservation) }
        routeObservation = nil
        pingTask = nil
        undoTask = nil
        upNextTask = nil
        fallbackTask = nil
        heartbeatTask = nil
    }

    private func invalidateCaches() async {
        await api.invalidate(ratingKey: request.ratingKey)
        if let seasonRatingKey = request.seasonRatingKey { await api.invalidate(ratingKey: seasonRatingKey) }
        if let showRatingKey = request.showRatingKey { await api.invalidate(ratingKey: showRatingKey) }
    }

    private func removePlayheadObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        if let playheadObserver {
            player?.removeTimeObserver(playheadObserver)
        }
        playheadObserver = nil
    }

    private func stopTranscodeIfNeeded() async {
        guard let stream, !stream.isDirectPlay else { return }
        do {
            try await api.requestVoid(.stopTranscode(session: stream.sessionId))
        } catch {
            MidgarLog.error("Stop transcode failed: \(error.localizedDescription)", category: .playback)
        }
    }
}
