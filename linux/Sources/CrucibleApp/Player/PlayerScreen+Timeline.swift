import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// What the player tells the server and the integrations as the playback goes, and how it ends.
extension PlayerScreen {
    /// The integrations that follow this title (Trakt scrobbling), made once for it: a stream restarted mid-play keeps
    /// them, so a play is never started twice.
    func startWatchers(for item: PlexMetadata, api: APIClient) {
        guard !watchersStarted else { return }
        watchersStarted = true
        watchers = Integrations.playbackWatchers(for: PlaybackSubject(
            ratingKey: item.id, mediaType: item.mediaType, showRatingKey: item.grandparentRatingKey, title: item.title,
            showTitle: item.grandparentTitle, seasonNumber: item.parentIndex, episodeNumber: item.index, durationSecs: duration,
            server: ServerBootstrap.savedMachineIdentifier ?? "", api: api))
    }

    func startReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(PlaybackTiming.timelineInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.keepPosition()
                self.report(self.player?.state.isPaused == true ? "paused" : "playing")
            }
        }
    }

    /// Keeps where the viewer is on this machine as playback goes, so a process that is ended by a crash, a logout or the
    /// machine losing power still knows: the next launch hands the server the position its last report never carried
    /// (`PlaybackResumeSync.flush`, in the launch pipeline). The write reaches the disk at once, since the point of it is a
    /// process that ends without being asked.
    func keepPosition(finished: Bool? = nil) {
        guard case .plex(_, let item, _) = source, duration > 0,
              let server = ServerBootstrap.savedMachineIdentifier, !server.isEmpty else { return }
        PlaybackResumeStore.shared.save(
            server: server,
            ratingKey: item.id,
            positionSecs: position,
            durationSecs: duration,
            finished: finished ?? WatchedRule.isFinished(positionSecs: position, durationSecs: duration, creditsStartSecs: upNext?.creditsStartSecs)
        )
        UserDefaults.standard.synchronize()
    }

    /// Beats four times a second for as long as the player is open: the sleep timer counts and fades on it, and a beat that
    /// comes long after the last one means the machine slept, which brings the player back where it was.
    func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.beat()
            }
        }
    }

    @discardableResult
    func report(_ playbackState: String) -> Task<Void, Never>? {
        guard stream != nil, duration > 0, case .plex(let api, let item, _) = source else { return nil }
        lastReportedState = playbackState
        let seconds = position
        let endpoint = PlexEndpoint.timeline(ratingKey: item.id, state: playbackState, timeMs: Int(seconds * 1000), durationMs: Int(duration * 1000))
        let server = ServerBootstrap.savedMachineIdentifier
        return Task {
            do {
                try await api.requestVoid(endpoint)
                if let server { PlaybackResumeStore.shared.recordReport(server: server, ratingKey: item.id, positionSecs: seconds) }
            } catch {
                MidgarLog.error("Timeline report failed: \(error)", category: .playback)
            }
        }
    }

    /// Stops playback, tells the server where it stopped and leaves.
    func close() {
        guard !closed else { return }
        closed = true
        scan?.task?.cancel()
        scan = nil
        window?.showsHDRContent = false
        settingsObservers.forEach { NotificationCenter.default.removeObserver($0) }
        settingsObservers = []
        MatchContent.release()
        resolveTask?.cancel()
        reportTask?.cancel()
        heartbeatTask?.cancel()
        pingTask?.cancel()
        revealTask?.cancel()
        metadataTask?.cancel()
        hideTask?.cancel()
        offerTask?.cancel()
        card?.stopCounting()
        alert?.dismiss()
        alert = nil
        contextMenu?.dismiss()
        calibration?.removeFromSuperview()
        calibration = nil
        closeWeb()
        closeLive()
        let finished = WatchedRule.isFinished(positionSecs: position, durationSecs: duration, creditsStartSecs: upNext?.creditsStartSecs)
        keepPosition(finished: finished)
        watchers.forEach { $0.playback(.stopped(position: position, finished: finished, at: Date())) }
        if finished { recordFinish() }
        watchers = []
        if let stopped = report("stopped") {
            let pending = Task { @MainActor in
                await stopped.value
                PlayerScreen.pendingStop = nil
            }
            PlayerScreen.pendingStop = pending
        }
        if let stream, !stream.isDirectPlay, case .plex(let api, _, _) = source {
            let session = stream.sessionId
            Task { try? await api.requestVoid(.stopTranscode(session: session)) }
        }
        player?.stop()
        player?.shutDown()
        player = nil
        controls?.close()
        controls = nil
        sessionWatch?.close()
        sessionWatch = nil
        ScreenAwake.hold(false, in: window)
        window?.setCursor(.default)
        window?.onDisplayColorChange = nil
        restoreWindow()
        onClose?()
    }

    /// Takes the window back out of full screen as the sitting's last title closes, whichever way it closes, when the sitting
    /// began in a window; a hand-over to the next title (no `onClose`) keeps it full screen.
    func restoreWindow() {
        guard onClose != nil, run.beganWindowed == true else { return }
        _ = LinuxDisplay.leaveFullscreen(window)
    }

    /// Notes a finished movie or episode in the ledger behind Rate What You Watched and the shows the viewer follows
    /// (`PlaybackSession.recordFinish`): an episode closed its season when the next one belongs to another season, and
    /// closed the show when there was nothing next; a playlist's entries close neither.
    func recordFinish() {
        guard case .plex(_, let item, _) = source else { return }
        let kind: FinishedTitle.Kind
        switch item.mediaType {
        case "movie": kind = .movie
        case "episode": kind = .episode
        default: return
        }
        var endedShow = false
        var endedSeason = false
        if kind == .episode, run.queue == nil {
            switch nextKnown {
            case .offer(let offer):
                endedSeason = offer.episode.parentIndex != nil && offer.episode.parentIndex != item.parentIndex
            case .nothingNext:
                endedShow = true
            case nil:
                break
            }
        }
        FinishedTitlesLedger.shared.record(FinishedTitle(
            ratingKey: item.id, kind: kind, title: item.title, showTitle: item.grandparentTitle, showRatingKey: item.grandparentRatingKey,
            seasonNumber: item.parentIndex, episodeNumber: item.index, posterPath: item.thumb, showPosterPath: item.grandparentThumb,
            finishedAt: Date(), endedShow: endedShow, endedSeason: endedSeason, librarySectionID: item.librarySectionID
        ), server: ServerBootstrap.savedMachineIdentifier)
    }
}
