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
        followPreload(of: item, since: .now)
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

    /// Says in the log how long the stream took to load far enough to show a picture, which is how much notice of a press
    /// Instant Start needs on this device and this server, and primes the player once it has.
    private func followPreload(of item: AVPlayerItem, since began: ContinuousClock.Instant) {
        let ratingKey = request.ratingKey
        preloadObserver = item.observe(\.status, options: [.new]) { @Sendable [weak self] observed, _ in
            guard observed.status != .unknown else { return }
            let milliseconds = Int((began.duration(to: .now).seconds * 1000).rounded())
            let outcome = observed.status == .readyToPlay ? "loaded" : "failed to load"
            MidgarLog.notice("Instant Start: ratingKey=\(ratingKey) \(outcome) in \(milliseconds) ms", category: .playback)
            Task { @MainActor in self?.primePreload() }
        }
    }

    /// Has a loaded player decode its first pictures and fill its sound pipeline, where it stands, without playing them.
    /// A player that has only loaded still takes a quarter of a second to do that after Play (260 ms on an iPad Pro M1);
    /// a primed one shows its picture in the time of a frame or three (45 to 72 ms). Priming needs the player to play the
    /// moment it is told to, so its own wait against stalls is off until `settleStallWait` puts it back. Nothing is primed
    /// while another app's sound is playing: the pipeline is left alone rather than risk that sound for a start that may
    /// never come.
    private func primePreload() {
        guard let player = preloaded, !preloadIsPrimed, !preloadSeekPending, player.currentItem?.status == .readyToPlay,
              !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        preloadIsPrimed = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preroll(atRate: 1, completionHandler: nil)
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
        preloadObserver = nil
        player.currentItem?.preferredForwardBufferDuration = 0
        startedPrimed = preloadIsPrimed
        settleStallWait()
        return player
    }

    /// Gives a primed player its wait against stalls back once its start is behind it: by then it plays from seconds of
    /// loaded stream, and from there on a stall is the player's to wait out as in any other playback.
    private func settleStallWait() {
        guard preloadIsPrimed else { return }
        preloadIsPrimed = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.player?.automaticallyWaitsToMinimizeStalling = true
        }
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
        primePreload()
        playIfAsked(autoplay: false)
    }

    /// Empties a preloaded player nobody asked for and stops the pings that kept its stream alive.
    func dropPreload() {
        guard let player = preloaded else { return }
        preloaded = nil
        preloadObserver = nil
        preloadSeekPending = false
        preloadIsPrimed = false
        pingTask?.cancel()
        pingTask = nil
        player.replaceCurrentItem(with: nil)
    }

    /// Notes when the first item of a start can show a picture, for the line that says where a start's time went.
    func followStart(of player: AVPlayer) {
        guard let item = player.currentItem else { return }
        guard item.status == .unknown else {
            noteFirstItemReady()
            return
        }
        startObserver = item.observe(\.status, options: [.new]) { @Sendable [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            Task { @MainActor in self?.noteFirstItemReady() }
        }
    }

    private func noteFirstItemReady() {
        startObserver = nil
        guard readyAfter == nil else { return }
        readyAfter = askedAt.map { Int(($0.duration(to: .now).seconds * 1000).rounded()) }
    }

    /// Says in the log how long the picture took from the press of Play, once, how much of that the stream took to load,
    /// and how ready the title was at the press. This is the number Instant Start exists for. `instant` is when the player
    /// itself said it was playing, which on a slow device is well before the main thread, busy putting the player on
    /// screen, gets to hear of it.
    func notePictureStarted(at instant: ContinuousClock.Instant) {
        guard let asked = askedAt else { return }
        askedAt = nil
        let milliseconds = Int((asked.duration(to: instant).seconds * 1000).rounded())
        let kind = stream.map { $0.isDirectPlay ? "file" : "converted" } ?? "none"
        let ready = readyAfter.map { " ready=\($0) ms" } ?? ""
        MidgarLog.notice("Playing ratingKey=\(request.ratingKey) \(milliseconds) ms after Play\(ready) start=\(startedFrom.logName)\(startedPrimed ? "+primed" : "") stream=\(kind)", category: .playback)
    }
}
