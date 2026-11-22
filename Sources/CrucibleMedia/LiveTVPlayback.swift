import AVFoundation
import CrucibleCore
import Foundation
import MediaPlayer
import MidgarCore

/// Plays live channels on the iPhone, the iPad and the Apple TV: works out how each channel plays (`LivePlayback`), relays a
/// bare transport stream through `LiveStreamRelay` so AVPlayer can show it, frees a tuner when the viewer moves on, and
/// keeps Now Playing and the remote's next and previous track (channel up and down) in step. Both apps' player screens
/// drive one of these.
@MainActor
package final class LiveTVPlayback {
    package let player = AVPlayer()
    package private(set) var channel: LiveChannel
    package let guide: LiveTVGuide?
    /// The channel watched before this one, for Previous Channel.
    package private(set) var previous: LiveChannel?
    /// Called on the main thread when a channel starts tuning, with it.
    package var onChannel: ((LiveChannel) -> Void)?
    /// Called once the picture of the current channel is ready.
    package var onReady: (() -> Void)?
    /// Called with a message when the channel could not be played.
    package var onFailure: ((String) -> Void)?

    private var plan: LivePlaybackPlan?
    private var relay: LiveStreamRelay?
    private var tuneTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var stopped = false
    private var triedCopies: Set<String> = []

    package init(channel: LiveChannel, guide: LiveTVGuide?) {
        self.channel = channel
        self.guide = guide
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        #endif
    }

    private var api: APIClient? { guide?.context.api }
    private var token: String { guide?.context.token ?? "" }

    package func start() {
        installRemoteCommands()
        tune(channel)
    }

    /// Plays `channel`, freeing the previous one's tuner and relay first.
    package func tune(_ channel: LiveChannel) {
        triedCopies = [channel.id]
        open(channel)
    }

    /// Plays the next copy of the current channel's station from another source, when the guide merged any.
    private func failOver(_ message: String) {
        guard !stopped, let next = guide?.alternates(of: channel.id).first(where: { !triedCopies.contains($0.id) }) else {
            onFailure?(message)
            return
        }
        MidgarLog.notice("Live channel \(channel.id) failed, trying its copy \(next.id)", category: .liveTV)
        triedCopies.insert(next.id)
        let previous = previous
        open(next)
        self.previous = previous
    }

    private func open(_ channel: LiveChannel) {
        guard !stopped else { return }
        if channel.id != self.channel.id { previous = self.channel }
        self.channel = channel
        onChannel?(channel)
        guide?.watched(channel.id)
        updateNowPlaying()
        let ending = (plan, relay)
        plan = nil
        relay = nil
        ending.1?.stop()
        let api = api
        let token = token
        tuneTask?.cancel()
        tuneTask = Task { [weak self] in
            if let plan = ending.0 { await LivePlayback.stop(plan, api: api) }
            do {
                let plan = try await LivePlayback.plan(for: channel, token: token, api: api)
                guard let self, !Task.isCancelled, !self.stopped else {
                    await LivePlayback.stop(plan, api: api)
                    return
                }
                self.plan = plan
                let url: URL
                var relayed = false
                switch plan.format {
                case .hls:
                    url = plan.url
                case .transportStream:
                    let relay = LiveStreamRelay(source: plan.url, headers: plan.headers)
                    self.relay = relay
                    switch try await relay.start() {
                    case .relayed(let local):
                        url = local
                        relayed = true
                    case .hls(let direct): url = direct
                    }
                }
                guard !Task.isCancelled, !self.stopped, self.channel.id == channel.id else { return }
                self.play(url, headers: relayed ? [:] : plan.headers, relayed: relayed)
            } catch {
                guard let self, !Task.isCancelled, !self.stopped else { return }
                MidgarLog.error("Live channel \(channel.id) failed: \(error)", category: .liveTV)
                self.failOver((error as? LocalizedError)?.errorDescription ?? ConnectionError.message(for: error))
            }
        }
    }

    private func play(_ url: URL, headers: [String: String], relayed: Bool) {
        var options: [String: Any] = [:]
        if !relayed {
            if let agent = headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = agent }
            let extra = headers.filter { $0.key != "User-Agent" }
            if !extra.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = extra }
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.externalMetadata = metadataItems()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay: self.onReady?()
                case .failed:
                    MidgarLog.error("Live item failed: \(message ?? "unknown")", category: .liveTV)
                    self.failOver(message ?? LiveStreamRelay.Failure.noPicture.localizedDescription)
                default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        MidgarLog.notice("Playing live channel \(channel.id)\(relayed ? " through the relay" : "")", category: .liveTV)
    }

    /// Channel up (`offset` 1) or down (-1) in the guide's list.
    package func zap(by offset: Int) {
        guard let next = guide?.channel(from: channel.id, offset: offset), next.id != channel.id else { return }
        tune(next)
    }

    package func previousChannel() {
        guard let previous else { return }
        tune(previous)
    }

    /// Ends playback, the relay and the tuner session.
    package func stop() {
        guard !stopped else { return }
        stopped = true
        tuneTask?.cancel()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        relay?.stop()
        relay = nil
        if let plan {
            let api = api
            Task { await LivePlayback.stop(plan, api: api) }
        }
        plan = nil
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// What airs now on the channel playing.
    package var nowAiring: LiveProgram? { guide?.nowAndNext(channel.id).now }

    private func metadataItems() -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, nowAiring?.title ?? channel.title), item(.iTunesMetadataTrackSubTitle, channel.numberedTitle)]
        if let summary = nowAiring?.summary { items.append(item(.commonIdentifierDescription, summary)) }
        return items
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowAiring?.title ?? channel.title,
            MPMediaItemPropertyArtist: channel.numberedTitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let episode = nowAiring?.episodeTitle { info[MPMediaItemPropertyAlbumTitle] = episode }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (LiveTVPlayback) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(center.nextTrackCommand) { $0.zap(by: 1) }
        add(center.previousTrackCommand) { $0.zap(by: -1) }
        add(center.playCommand) { $0.player.play() }
        add(center.pauseCommand) { $0.player.pause() }
        add(center.togglePlayPauseCommand) { playback in
            if playback.player.timeControlStatus == .paused { playback.player.play() } else { playback.player.pause() }
        }
    }

    private func removeRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
    }
}
