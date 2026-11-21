import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

extension PlaybackSession {
    /// Loads the prepared stream into a paused player, at the place playback will start from, before any surface asks for
    /// it: `begin()` then plays that player instead of making one, so its picture is there the moment it is shown. Until
    /// then the player is nobody's: it reports nothing to the server, holds no title, takes no remote command and stays
    /// off AirPlay. A converted stream starts on the server here, and is kept alive by its pings. Does nothing for a
    /// downloaded title, which loads from disk in no time anyway, or when there is no prepared stream.
    package func preload() {
        guard let stream, player == nil, preloaded == nil, !isStopped, request.offline == nil else { return }
        let item = AVPlayerItem(url: stream.url)
        item.preferredForwardBufferDuration = WarmStartRule.forwardBuffer
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.appliesMediaSelectionCriteriaAutomatically = false
        preloaded = player
        if !stream.isDirectPlay { startPing(session: stream.sessionId) }
        guard case .seekExact(let position) = ResumeStrategy.make(
            resumePosition: request.resumePosition,
            isDirectPlay: stream.isDirectPlay,
            isOffline: false
        ) else { return }
        preloadSeekPending = true
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor in self?.preloadSeekLanded() }
        }
    }

    /// Whether a preloaded player has its stream loaded far enough to show a picture at once.
    package var isLoaded: Bool {
        preloaded?.currentItem?.status == .readyToPlay && !preloadSeekPending
    }

    /// How far the session has been made ready so far.
    package var warmth: WarmDepth {
        if preloaded != nil { return .loaded }
        return stream == nil ? .none : .resolved
    }

    /// Hands the preloaded player over to `begin()`, loading as far ahead as a playing stream does from here on.
    func takePreload() -> AVPlayer? {
        guard let player = preloaded else { return nil }
        preloaded = nil
        player.currentItem?.preferredForwardBufferDuration = 0
        return player
    }

    /// Starts a preloaded player: at once when it already stands where playback starts, and otherwise the moment its seek
    /// lands, so it never shows a moment of the item's beginning first.
    func startPreloaded(_ player: AVPlayer, autoplay: Bool) {
        if preloadSeekPending {
            playsAfterResume = autoplay
        } else if autoplay {
            player.play()
        }
    }

    private func preloadSeekLanded() {
        preloadSeekPending = false
        guard !isStopped else { return }
        playIfAsked(autoplay: false)
    }

    /// Empties a preloaded player nobody asked for and stops the pings that kept its stream alive.
    func dropPreload() {
        guard let player = preloaded else { return }
        preloaded = nil
        preloadSeekPending = false
        pingTask?.cancel()
        pingTask = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Says in the log how long the picture took from the press of Play, once, and how ready the title was by then. This
    /// is the number Instant Start exists for.
    func notePictureStarted() {
        guard let asked = askedAt else { return }
        askedAt = nil
        let milliseconds = Int((asked.duration(to: ContinuousClock.now).seconds * 1000).rounded())
        let kind = stream.map { $0.isDirectPlay ? "file" : "converted" } ?? "none"
        MidgarLog.notice("Playing ratingKey=\(request.ratingKey) \(milliseconds) ms after Play start=\(startedFrom.logName) stream=\(kind)", category: .playback)
    }
}
