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
    package private(set) var request: PlaybackRequest
    /// Whether this session counts as a player that has its title open, which keeps the device's saved position of it from
    /// being sent while it plays.
    private var holdsPlayingTitle = false
    /// How long a start waits to learn where the server has the title before it goes with the screen's copy.
    private static let serverStartGrace: Duration = .seconds(2)
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
    /// Watches what a converted stream shows, so a picture the server's decoder painted a flat colour is reported
    /// (`PictureWatcher`) instead of played on in silence.
    var pictureWatcher: PictureWatcher?
    /// Whether the viewer was already told this playback has no picture, so the one alert is never repeated by a rebuild.
    var hasReportedPictureTrouble = false
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
    /// Where the playhead was, on the player's clock, when the viewer put a finger on the scrubber; nil with no finger down.
    var scrubOrigin: Double?
    var scrubSettleTask: Task<Void, Never>?
    var hurryTask: Task<Void, Never>?
    var isRestarting = false
    var pendingRestart: PendingRestart?
    var restartResumesPlayback = true
    /// The exact place on the item's timeline the latest rebuild was asked for, which it opens a little before.
    var restartTarget: Double?
    var awayDetector = AwayDetector()
    var awaySince: ContinuousClock.Instant?
    var positionAtLastBeat: Double?
    var settlingUntil: ContinuousClock.Instant?
    /// The times the system player may carry over onto the rebuilt transcode from the item before it (`CarriedTimes`).
    var carriedTimes: CarriedTimes?
    /// Where the item on screen showed the viewer, on its own clock, when the rebuild that replaces it was asked for.
    var clockShownBeforeRebuild: Double?
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
    var fadeTask: Task<Void, Never>?
    /// Whether the player was playing when an audio interruption began, which is the only case its end may resume.
    var playingBeforeInterruption = false
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
    /// What the surface showing the player can say about the screen, for the picture line in the log.
    package var describesDisplay: (@MainActor () -> String?)?
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
    /// The resolve in flight, which a second `prepare()` joins instead of asking the server again.
    private var resolving: Task<ResolvedStream, any Error>?
    /// A paused player loading the prepared stream ahead of `begin()`, which then plays it (`preload()`).
    var preloaded: AVPlayer?
    var preloadObserver: NSKeyValueObservation?
    /// Whether the preloaded player has been primed to show its picture at once (`primePreload`).
    var preloadIsPrimed = false
    var startedPrimed = false
    /// Follows the first item of a start until it can show a picture (`followStart`).
    var startObserver: NSKeyValueObservation?
    /// How long after Play the first item could show a picture, for the line that says how long the start took.
    var readyAfter: Int?
    /// Whether the seek that puts a preloaded player at the place playback starts from is still on its way.
    var preloadSeekPending = false
    /// How far this session had been made ready when Play was pressed, and when that was, for the line that says how long the
    /// picture took.
    package var startedFrom: WarmDepth = .none
    package var askedAt: ContinuousClock.Instant?

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

    /// A session dropped without `stop()` gives its title back, so the device's saved position of it is reported again.
    deinit {
        guard holdsPlayingTitle else { return }
        let ratingKey = request.ratingKey
        Task { @MainActor in PlaybackResumeSync.ended(ratingKey) }
    }

    /// The sessions that have a player on a surface, held weakly, for `isAnyPlaying`.
    private static let begun = NSHashTable<PlaybackSession>.weakObjects()

    /// Whether any session has a player that has not been stopped, playing or paused.
    package static var isAnyPlaying: Bool {
        begun.allObjects.contains { $0.player != nil && !$0.isStopped }
    }

    /// Whether the session is over (`stop()` or `discard()`), so it can play nothing any more.
    package var isSpent: Bool { isStopped }

    /// The item's timeline position of the playhead, or nil before playback starts.
    package var absolutePosition: Double? {
        guard let player else { return nil }
        let seconds = player.currentTime().seconds
        if isCarriedOver(seconds) { return tracker.lastGoodPosition }
        return tracker.position(playerSeconds: seconds, isReady: isItemReady)
    }

    /// Whether the player's clock reads a time the system player carried over onto a rebuilt transcode from the item before it,
    /// rather than where the viewer is.
    func isCarriedOver(_ reading: Double) -> Bool {
        carriedTimes?.isCarried(reading, home: max(0, streamStart - streamOffset), at: now()) ?? false
    }

    /// Where a seek the system player is about to make to `seconds` on its clock should land: a time carried over from the item a
    /// rebuild replaced goes to where the rebuilt stream starts instead.
    package func seekTarget(forPlayerSeconds seconds: Double) -> Double {
        isCarriedOver(seconds) ? max(0, streamStart - streamOffset) : seconds
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
    /// server already started is stopped. A downloaded item is ready without a network round trip. A session
    /// resolves once: a call made while another is still resolving waits for the same answer, which is how a Play
    /// pressed while the title was being made ready picks up where that got to.
    package func prepare() async throws -> ResolvedStream {
        if isStopped { throw CancellationError() }
        if let stream { return stream }
        let task = resolving ?? Task { try await self.resolveStream() }
        resolving = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func resolveStream() async throws -> ResolvedStream {
        defer { resolving = nil }
        await catchUpWithServer()
        if isStopped || Task.isCancelled { throw CancellationError() }
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
        guard !Task.isCancelled, !isStopped else {
            discardTranscode(of: resolved)
            throw CancellationError()
        }
        stream = resolved
        selectedSubtitleId = resolved.chosenSubtitleId
        selectedAudioStreamId = resolved.chosenAudioStreamId
        subtitlesTurnedOff = resolved.chosenSubtitleId == nil && languages?.subtitlesOff == true
        return resolved
    }

    /// A start read off a screen's copy of the title moves to where the title is now: the server's place, or this device's
    /// own run when the server has not heard of it yet. The resolver reads the same metadata next, so this costs no extra
    /// request. A server slower than `serverStartGrace` or failing leaves the start as the screen had it, and its answer still
    /// serves the resolver.
    private func catchUpWithServer() async {
        guard request.serverStart != nil, request.offline == nil else { return }
        let api = api
        let ratingKey = request.ratingKey
        let lookup = Task { try? await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first }
        guard let answer = await Settle.value(of: lookup, within: Self.serverStartGrace), let item = answer,
              let followed = request.followingServer(item, devicePoint: resumeStore.point(server: serverID, ratingKey: ratingKey)) else { return }
        MidgarLog.notice("Starting \(request.ratingKey) at \(Int(followed.resumePosition)) s where the server has it, not \(Int(request.resumePosition)) s", category: .playback)
        request = followed
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
        resolving?.cancel()
        dropPreload()
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
        let ready = takePreload()
        let player = ready ?? AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        self.player = player
        Self.begun.add(self)
        PlaybackWarmUp.shared.began(self)
        if !request.isExtra {
            PlaybackResumeSync.began(request.ratingKey)
            holdsPlayingTitle = true
        }
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
        sharpenIntro(of: stream)
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
        expectPicture()
        startHeartbeat()
        watchCurrentItem()
        if ready == nil {
            startPlayback(player: player, stream: stream, resumePosition: request.resumePosition, autoplay: autoplay)
        } else {
            startPreloaded(player, autoplay: autoplay)
        }
        followStart(of: player)
        return player
    }

    /// Ends playback: stops the transcode, reports the final position, drops cached metadata of the
    /// item, its season and its show, and releases the player. An item the viewer finished is reported at
    /// its very end, which is what ends it in Continue Watching and counts it as watched on a server whose
    /// completion rule does not happen to be the one this item's credits cross. Returns the playhead at the
    /// moment of the stop so a caller can persist it. `keepsLastFrame` pauses the player instead of emptying it,
    /// for a surface that keeps the picture on screen until it has gone and then releases the player itself.
    @discardableResult
    package func stop(keepsLastFrame: Bool = false) async -> Double? {
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
        startObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil

        if let finalPosition {
            let date = Date()
            watchers.forEach { $0.playback(.stopped(position: finalPosition, finished: finished, at: date)) }
        }
        watchers = []
        await invalidateCaches()
        if player != nil { keepPosition(finalPosition, finished: finished) }
        let reported = reporter != nil
        await reporter?.stop(positionSecs: Self.reportPosition(for: finalPosition, finished: finished, duration: request.durationSecs))
        reporter = nil
        releasePlayingTitle()
        if reported { announceStop() }
        if finished { recordFinish() }
        removePlayheadObservers()
        await stopTranscodeIfNeeded()

        if keepsLastFrame {
            player?.pause()
        } else {
            player?.replaceCurrentItem(with: nil)
        }
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
        for task in [pingTask, undoTask, upNextTask, fallbackTask, heartbeatTask, routeCheckTask, rebuildTask, subtitleSyncTask, fadeTask] { task?.cancel() }
        fadeTask = nil
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
        pictureWatcher?.invalidate()
        pictureWatcher = nil
    }

    private func invalidateCaches() async {
        await api.invalidate(ratingKey: request.ratingKey)
    }

    private func releasePlayingTitle() {
        guard holdsPlayingTitle else { return }
        holdsPlayingTitle = false
        PlaybackResumeSync.ended(request.ratingKey)
    }

    /// Once the server holds the final position, every screen showing the item, its season or its show reads them again.
    private func announceStop() {
        ServerStateSync.shared.post(.titles([request.ratingKey, request.seasonRatingKey, request.showRatingKey]))
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

extension PlaybackSession {
    /// Takes the intro a paired Crucible Server moved onto the picture's edges, while the same stream plays and the
    /// playhead has not reached the intro yet.
    func sharpenIntro(of stream: ResolvedStream) {
        let segments = stream.segments
        guard !request.isExtra, request.offline == nil, segments.contains(where: { $0.kind == .intro && !$0.fromChapter }) else { return }
        let ratingKey = request.ratingKey
        Task { [weak self] in
            guard let sharpened = await IntroSharpening.fromServer(segments, ratingKey: ratingKey),
                  let self, !self.isStopped, self.stream?.sessionId == stream.sessionId,
                  let intro = sharpened.first(where: { $0.kind == .intro }), self.bestKnownPosition < intro.startSecs else { return }
            self.markerTracker = MarkerTracker(segments: sharpened)
        }
    }
}
