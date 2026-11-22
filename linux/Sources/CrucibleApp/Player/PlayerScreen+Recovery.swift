import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// The player when a stream fails or has to be read again, and its pre-roll before the picture shows.
extension PlayerScreen {
    /// Answers a failed stream as `PlaybackSession` does: a file that fails to play as it is gets converted by the server
    /// from the playhead, once; anything else says so with Retry, and stops keeping the dead session alive, whose ping would
    /// otherwise rebuild it behind the error every 20 seconds.
    func recover(from message: String) {
        if web != nil {
            recoverWeb(from: message)
            return
        }
        switch failurePolicy.decide(wasDirectPlay: stream?.isDirectPlay ?? false, isOffline: false) {
        case .fallBackToTranscode:
            fallBackToTranscode(after: message)
        case .ignore:
            break
        case .restartTranscode, .fail:
            pingTask?.cancel()
            presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Plays the file converted by the server from where direct play stopped, or from the resume point when it never started.
    func fallBackToTranscode(after message: String) {
        guard case .plex(_, let item, let resumePosition) = source else { return }
        let start = PlaybackFailurePolicy.fallbackStart(lastAbsolute: position, resumePosition: resumePosition)
        MidgarLog.notice("Direct play of \(item.id) failed (\(message)); converting from \(Int(start)) s", category: .playback)
        convertsAfterFailure = true
        reloadStream(at: start, freshSession: false) { [weak self] in
            self?.failurePolicy.recordFailure()
            self?.presentFailure(message, retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Plays again from where it failed, in the same tracks.
    func retryFromPlayhead() {
        failurePolicy = PlaybackFailurePolicy()
        if web != nil {
            resolveWeb(fresh: true, at: stream == nil ? nil : position)
            return
        }
        guard stream != nil else {
            resolveFirstStream()
            return
        }
        let at = position
        reloadStream(at: at, freshSession: true) { [weak self] in
            self?.presentFailure(String(localized: "The server didn’t answer."), retry: { [weak self] in self?.retryFromPlayhead() })
        }
    }

    /// Playback Error with Retry and Close (`TVPlayerCoordinator.presentFailure`); Escape closes. One alert at a time.
    func presentFailure(_ message: String, retry: (() -> Void)?) {
        guard alert == nil, !closed, let window else { return }
        var actions = [AlertView.Action(String(localized: "Close", comment: "Alert button that dismisses the error"), role: .cancel) { [weak self] in
            self?.alert = nil
            self?.close()
        }]
        if let retry {
            actions.insert(AlertView.Action(String(localized: "Retry")) { [weak self] in
                self?.alert = nil
                retry()
            }, at: 0)
        }
        let shown = AlertView(title: String(localized: "Playback Error"), message: String(localized: "This video couldn’t be played.\n\(message)"),
                              actions: actions)
        alert = shown
        shown.present(in: window)
    }

    /// A drag along the scrubber: playback holds while it moves, and the picture follows the pointer by keyframe seeks when
    /// seeks on this file land quickly; from a slow source (a spinning disk behind the server) the preview stills carry the
    /// drag instead. Letting go seeks exactly, shows the still for that moment until the picture arrives, and plays on if
    /// it was playing. The place it started from is kept for Go Back, and the server and Trakt hear nothing of the hold.
    func scrub(to fraction: Float, phase: TransportView.ScrubPhase) {
        guard duration > 0 else { return }
        let target = Double(fraction) * duration
        switch phase {
        case .began:
            scrubOrigin = position
            scrubResumes = player?.state.isPaused == false
            if scrubResumes { player?.setPaused(true) }
            if dragMovesPicture { seek(to: target, mode: .keyframe) }
        case .moved:
            if dragMovesPicture { seek(to: target, mode: .keyframe) }
        case .ended:
            seek(to: target)
            if scrubResumes { player?.setPaused(false) }
            if let scrubOrigin { noteJump(from: scrubOrigin, to: target) }
            scrubOrigin = nil
            scrubResumes = false
        }
    }

    /// `CRUCIBLE_PLAYER_SLEEP_TIMER=<seconds>` starts with a timed sleep timer that runs out that many seconds later (`end`
    /// for one that stops at the end of the item), and `CRUCIBLE_PLAYER_UNATTENDED=<n>` as if `n` episodes had played with
    /// nobody at the keyboard, so headless checks reach the end of a timer and "Still watching?" without waiting for them.
    func applyTestPresets() {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["CRUCIBLE_PLAYER_SLEEP_TIMER"], run.sleepTimer == nil {
            if value == "end" {
                sleepTimer = SleepTimer(choice: .endOfItem)
            } else if let seconds = Double(value) {
                sleepTimer = SleepTimer(choice: .minutes(15), now: Date().addingTimeInterval(seconds - 15 * 60))
            }
            transport.isSleepTimerSet = sleepTimer != nil
        }
        if let count = environment["CRUCIBLE_PLAYER_UNATTENDED"].flatMap(Int.init) {
            run.unattendedEpisodes = count
            run.viewerActedThisEpisode = false
        }
    }


    func showPreroll() {
        let headline = prerollHeadline
        let shown = PrerollView(title: headline.title, subtitle: headline.subtitle, posterPath: headline.posterPath, isLandscape: web != nil)
        preroll = shown
        insertSubview(shown, below: transport)
        chrome.reset(0)
        pacePlayheadReports()
        setNeedsLayout()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: PrerollView.revealTimeout)
            guard let self, !Task.isCancelled else { return }
            self.revealPicture()
        }
    }

    /// The pre-roll's title and its episode or year line, before the server's full record arrives.
    var prerollHeadline: (title: String, subtitle: String?, posterPath: String?) {
        switch source {
        case .file(_, let title):
            return (title, nil, nil)
        case .live(let session):
            return (session.channel.numberedTitle, session.guide?.nowAndNext(session.channel.id).now?.title, nil)
        case .web(let playback):
            let entry = web?.video.map(WebEntry.init) ?? playback.entry
            return (entry.title, entry.channel, WebArtwork.url(entry.thumbnailCandidates)?.absoluteString)
        case .plex(_, let item, _):
            if let show = item.grandparentTitle {
                let code = Formatters.episodeCode(item.parentIndex, item.index)
                return (item.title, [show, code].compactMap { $0 }.joined(separator: " · "), item.grandparentThumb ?? item.thumb)
            }
            let line = [item.year.map(String.init), item.contentRating].compactMap { $0 }.joined(separator: " · ")
            return (item.title, line.isEmpty ? nil : line, item.thumb)
        }
    }

    /// Dissolves from the pre-roll into the picture, the transport coming up with it.
    func revealPicture() {
        revealTask?.cancel()
        guard let preroll, !preroll.isRevealed else { return }
        preroll.reveal()
        self.preroll = nil
        showChrome(autoHide: true)
        notePictureStarted()
    }

    /// Says in the log how long the picture took from Play, once, and whether Instant Start had the stream by then.
    private func notePictureStarted() {
        guard let asked = askedAt, case .plex(_, let item, _) = source else { return }
        askedAt = nil
        let elapsed = asked.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        MidgarLog.notice("Playing ratingKey=\(item.id) \(milliseconds) ms after Play start=\(startedFrom.logName)", category: .playback)
    }
}
