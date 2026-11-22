import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The player's Up Next card, its own play controls and the skips over intros and credits.
extension PlayerScreen {
    /// Asks for the next episode; shows the card, or plays at once when asked for, or what's next at the end with none.
    func offerNext(_ reason: UpNextOffer.Reason) {
        guard let resolver = upNext, case .plex(let api, _, _) = source else {
            if reason != .credits, playNextWeb(byViewer: reason == .requested) { return }
            if reason == .playbackEnded { endOfPlayback() }
            return
        }
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            let answer = await Result { try await resolver.loadOffer(api: api, reason: reason) }
            guard let self, !Task.isCancelled, !self.closed else { return }
            if case .success(let found) = answer { self.nextKnown = found.map(NextKnown.offer) ?? .nothingNext }
            guard case .success(let found) = answer, let offer = found else {
                if reason == .playbackEnded { self.endOfPlayback() }
                return
            }
            if reason == .requested {
                self.playNext(offer, byViewer: true)
            } else {
                self.show(offer)
            }
        }
    }

    func show(_ offer: UpNextOffer) {
        card?.removeFromSuperview()
        let next = UpNextCard(offer: offer, asksStillWatching: run.asksStillWatching, stopsAfterItem: sleepTimer?.stopsAtEndOfItem == true)
        next.onPlay = { [weak self] byViewer in self?.playNext(offer, byViewer: byViewer) }
        next.onLeave = { [weak self] in
            self?.viewerActed()
            if offer.playbackEnded { self?.close() } else { self?.dismissCard() }
        }
        card = next
        addSubview(next)
        setNeedsLayout()
        next.appearNow()
        window?.focus.focus(next, animated: false)
        showChrome(autoHide: true)
    }

    /// `CRUCIBLE_UPNEXT_DEMO=1` with a local file shows the Up Next card two seconds in, for headless checks of its look.
    func showDemoUpNextIfAsked() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_UPNEXT_DEMO"] == "1" else { return }
        let json = #"{"ratingKey":"demo-2","key":"/library/metadata/2","type":"episode","title":"What the Bees Know","index":2,"parentIndex":1}"#
        guard let episode = try? JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8)) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.show(UpNextOffer(episode: episode, seasonRatingKey: "demo", reason: .credits, autoplays: true))
        }
    }

    func dismissCard() {
        card?.stopCounting()
        card?.removeFromSuperview()
        card = nil
        window?.focus.focus(self, animated: false)
    }

    /// Ends this playback (the server hears it stopped) and hands the next episode, or the playlist's next entry, on with the
    /// run it continues.
    func playNext(_ offer: UpNextOffer, byViewer: Bool) {
        let next = run.advancing(byViewer: byViewer, languages: trackLanguages, sleepTimer: sleepTimer, queue: offer.queue)
        let hand = onPlayNext
        onClose = nil
        close()
        hand?(offer.episode, next)
    }

    var showTitle: String? {
        if case .plex(_, let item, _) = source { return item.grandparentTitle }
        return web?.video?.channel ?? web?.playback.entry.channel
    }

    func perform(_ command: MediaControls.Command) {
        guard let player else { return }
        switch command {
        case .playPause: togglePause()
        case .play: player.setPaused(false)
        case .pause: player.setPaused(true)
        case .stop: close()
        case .seek(let offset):
            guard offset != 0 else { return }
            seek(to: playhead + Double(offset > 0 ? Preferences.skipForwardSeconds : -Preferences.skipBackSeconds))
        case .setPosition(let target): seek(to: target)
        case .next: if live != nil { zap(by: 1) } else { offerNext(.requested) }
        case .previous: if live != nil { zap(by: -1) } else { startOver() }
        case .raise: window?.raise()
        case .quit: MediaControls.onQuit?()
        }
    }

    func togglePause() {
        player?.togglePause()
    }

    /// Seeks to `absolute` on the title's timeline; a long exact jump shows the preview still there until the picture lands.
    /// A converted stream starts where the server began it, so a place before that asks the server for the stream again
    /// from there (a drag waits for its release).
    func seek(to absolute: Double, mode: VideoPlayer.SeekMode = .exact) {
        let target = min(max(absolute, 0), max(duration - 1, 0))
        if let stream, !stream.isDirectPlay, target < streamOffset - 0.5 {
            guard mode == .exact else { return }
            seekTarget = (target, .now)
            veil(at: target)
            reloadStream(at: target, freshSession: false, paused: player?.state.isPaused ?? false)
            return
        }
        if mode == .exact, abs(target - position) >= Self.jumpWorthReturning { veil(at: target) }
        seekTarget = (target, .now)
        stills?.titleSeeks(true)
        player?.seek(to: target - streamOffset, mode: mode)
        controls?.seeked(to: target)
        showChrome(autoHide: true)
    }

    /// Back to the start of the title, playing on if it was playing.
    func startOver() {
        seek(to: 0)
    }


    /// Shows Skip Intro, Skip Credits and the like inside a segment, or skips it at once when this title's rules or
    /// Settings say so (once per segment, so seeking back into it plays it), then offers Undo Skip for a few seconds.
    func updateSkip() {
        if let undo {
            if ContinuousClock.now < undo.until { return }
            self.undo = nil
        }
        let now = position
        if let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs - 1 }), card == nil {
            switch skipDecision(for: segment) {
            case .ignore:
                if !skip.isHidden { skip.isHidden = true }
            case .skip where !autoSkipped.contains(segment):
                autoSkipped.insert(segment)
                seek(to: segment.endSecs)
                offerUndo(returningTo: now)
            case .skip, .offer:
                showSkip(title: skipTitle(of: segment), symbol: "forward.end.fill")
            }
        } else if !skip.isHidden {
            skip.isHidden = true
        }
    }

    func showSkip(title: String, symbol: Symbol) {
        skip.title = title
        skip.symbol = symbol
        if skip.isHidden {
            skip.isHidden = false
            setNeedsLayout()
        }
    }

    func offerUndo(returningTo position: Double) {
        undo = (position, ContinuousClock.now.advanced(by: PlaybackTiming.autoSkipUndoWindow))
        showSkip(title: String(localized: "Undo Skip"), symbol: "arrow.uturn.backward")
    }

    func skipSegment() {
        if let undo {
            self.undo = nil
            skip.isHidden = true
            seek(to: undo.returnTo)
            return
        }
        let now = position
        guard let segment = segments.first(where: { now >= $0.startSecs && now < $0.endSecs }) else { return }
        if segment.isCredits && segment.endSecs >= duration - 2 {
            close()
        } else {
            seek(to: segment.endSecs)
        }
    }
}
