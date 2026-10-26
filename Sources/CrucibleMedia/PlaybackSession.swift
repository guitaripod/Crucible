import AVFoundation
import CrucibleCore
import Foundation

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
    package internal(set) var streamOffset: Double = 0 {
        didSet { tracker.setStreamOffset(streamOffset) }
    }
    package internal(set) var selectedSubtitleId: Int?
    package internal(set) var selectedAudioStreamId: Int?

    /// Called with every `AVPlayerItem` the session puts in the player (the first, a restarted
    /// transcode, a fallback, a re-resolved stream) so the surface can attach item-level state
    /// such as external metadata or a content proposal. The session's `streamOffset` already
    /// describes the item when it runs.
    package var configureItem: (@MainActor (AVPlayerItem) -> Void)?

    let api: APIClient
    let tracker = PlayheadTracker()
    let resumeStore: PlaybackResumeStore
    let serverID: String
    let continuation: AsyncStream<PlaybackEvent>.Continuation
    var reporter: PlaybackReporter?
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
    let installsRemoteCommands: Bool
    var isChangingStreams = false
    var isStopped = false
    var isUpNextVisible = false
    var isUndoVisible = false
    var pingTask: Task<Void, Never>?
    var undoTask: Task<Void, Never>?
    var upNextTask: Task<Void, Never>?
    var fallbackTask: Task<Void, Never>?

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
        self.request = request
        self.installsRemoteCommands = installsRemoteCommands
        selectedSubtitleId = request.selectedSubtitleId
        selectedAudioStreamId = request.selectedAudioStreamId
        let pair = AsyncStream.makeStream(of: PlaybackEvent.self)
        events = pair.stream
        continuation = pair.continuation
        upNext = UpNextResolver(
            ratingKey: request.ratingKey,
            isEpisode: request.isEpisode,
            seasonRatingKey: request.seasonRatingKey,
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
        let resolved = try await StreamResolver.resolve(
            api: api,
            ratingKey: request.ratingKey,
            startSecs: request.transcodeStartSecs,
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioStreamId
        )
        guard !Task.isCancelled else {
            discardTranscode(of: resolved)
            throw CancellationError()
        }
        stream = resolved
        return resolved
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
    /// is no prepared stream, playback already began, or the session is spent.
    package func begin() -> AVPlayer? {
        guard let stream, player == nil, !isStopped else { return nil }
        streamOffset = ResumeStrategy.streamOffset(resumePosition: request.resumePosition, isDirectPlay: stream.isDirectPlay)
        tracker.moved(to: request.resumePosition)
        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        self.player = player
        if let item = player.currentItem { configureItem?(item) }
        let reporter = PlaybackReporter(
            api: api,
            ratingKey: request.ratingKey,
            durationMs: Int(request.durationSecs * 1000),
            player: player,
            tracker: tracker,
            resumeStore: resumeStore,
            server: serverID
        )
        self.reporter = reporter

        markerTracker = MarkerTracker(markers: stream.markers)
        upNext = UpNextResolver(
            ratingKey: request.ratingKey,
            isEpisode: request.isEpisode,
            seasonRatingKey: request.seasonRatingKey,
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
        startPlayback(player: player, stream: stream, resumePosition: request.resumePosition, autoplay: true)
        return player
    }

    /// Ends playback: stops the transcode, reports the final position, drops cached metadata of the
    /// item, its season and its show, and releases the player. Returns the playhead at the moment of
    /// the stop so a caller can persist it.
    @discardableResult
    package func stop() async -> Double? {
        guard !isStopped else { return nil }
        isStopped = true
        let finalPosition = finalPlayhead()
        remoteCommands?.tearDown()
        remoteCommands = nil
        cancelBackgroundWork()
        itemWatcher?.invalidate()
        itemWatcher = nil
        restartItemObserver?.invalidate()
        restartItemObserver = nil
        offlineResumeObserver?.invalidate()
        offlineResumeObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil

        await invalidateCaches()
        await reporter?.stop(positionSecs: finalPosition)
        reporter = nil
        if player != nil { keepPosition(finalPosition) }
        removePlayheadObservers()
        await stopTranscodeIfNeeded()

        player?.replaceCurrentItem(with: nil)
        player = nil
        stream = nil
        continuation.finish()
        return finalPosition
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
        for task in [pingTask, undoTask, upNextTask, fallbackTask, heartbeatTask] { task?.cancel() }
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
            AppLogger.error("Stop transcode failed: \(error.localizedDescription)", .playback)
        }
    }
}
