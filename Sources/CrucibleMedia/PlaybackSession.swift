import AVFoundation
import CrucibleCore
import Foundation

/// One playback of one item, from stream resolution to teardown, independent of any screen.
///
/// A surface calls `prepare()` (or relies on the offline stream a downloaded item starts with),
/// decides whether it can present, then either `begin()`s playback and hosts the returned player or
/// `discard()`s the stream. While it runs the session reports through `events`; `stop()` ends it.
/// Resume follows `ResumeStrategy`: a transcode starts at the stored position through its URL offset
/// and is never seeked again.
@MainActor
package final class PlaybackSession {
    package let request: PlaybackRequest
    package let events: AsyncStream<PlaybackEvent>
    package internal(set) var player: AVPlayer?
    package internal(set) var stream: ResolvedStream?
    package internal(set) var streamOffset: Double = 0

    let api: APIClient
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
    var isRestarting = false
    var isStopped = false
    var isUpNextVisible = false
    var isUndoVisible = false
    var pingTask: Task<Void, Never>?
    var undoTask: Task<Void, Never>?
    var upNextTask: Task<Void, Never>?
    var fallbackTask: Task<Void, Never>?

    package init(api: APIClient, request: PlaybackRequest) {
        self.api = api
        self.request = request
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
        return StreamPosition.absolute(playerSeconds: player.currentTime().seconds, streamOffset: streamOffset)
    }

    /// Resolves the stream to play. A cancelled caller gets `CancellationError` and any transcode the
    /// server already started is stopped. A downloaded item is ready without a network round trip.
    package func prepare() async throws -> ResolvedStream {
        if let stream { return stream }
        let resolved = try await StreamResolver.resolve(
            api: api,
            ratingKey: request.ratingKey,
            startSecs: request.transcodeStartSecs,
            selectedSubtitleId: request.selectedSubtitleId,
            selectedAudioStreamId: request.selectedAudioStreamId
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
    /// player in its own surface; the session keeps driving it until `stop()`.
    package func begin() -> AVPlayer {
        guard let stream, player == nil, !isStopped else {
            preconditionFailure("begin() needs a prepared stream and a session that has not started or stopped")
        }
        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = true
        self.player = player

        streamOffset = ResumeStrategy.streamOffset(resumePosition: request.resumePosition, isDirectPlay: stream.isDirectPlay)
        let reporter = PlaybackReporter(
            api: api,
            ratingKey: request.ratingKey,
            durationMs: Int(request.durationSecs * 1000),
            player: player
        )
        reporter.setStreamOffset(streamOffset)
        self.reporter = reporter

        markerTracker = MarkerTracker(markers: stream.markers)
        upNext = UpNextResolver(
            ratingKey: request.ratingKey,
            isEpisode: request.isEpisode,
            seasonRatingKey: request.seasonRatingKey,
            markers: stream.markers
        )
        configureRemoteCommands()
        if !stream.isDirectPlay { startPing(session: stream.sessionId) }
        observeInterruptions()
        observePlayhead(of: player)
        watchCurrentItem()
        startPlayback(player: player, stream: stream)
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

        await reporter?.stop()
        reporter = nil
        await invalidateCaches()
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
        Task { [api] in
            try? await api.requestVoid(.stopTranscode(session: stream.sessionId))
        }
    }

    private func finalPlayhead() -> Double? {
        let seconds = player?.currentTime().seconds ?? lastPlayhead
        return StreamPosition.absolute(playerSeconds: seconds, streamOffset: streamOffset)
    }

    private func cancelBackgroundWork() {
        for task in [pingTask, undoTask, upNextTask, fallbackTask] { task?.cancel() }
        pingTask = nil
        undoTask = nil
        upNextTask = nil
        fallbackTask = nil
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
