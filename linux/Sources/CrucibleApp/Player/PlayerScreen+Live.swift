import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A live channel handed to the player, with the guide it came from for changing channel.
@MainActor
final class LiveSession {
    var channel: LiveChannel
    let guide: LiveTVGuide?
    var plan: LivePlaybackPlan?
    /// The channel watched before this one, for Previous Channel.
    var previous: LiveChannel?
    /// Digits typed to go to a channel by its number.
    var typed = ""
    /// The copies of the station tried since the viewer chose it, so a failing one falls over to each other copy once.
    var triedCopies: Set<String> = []
    var typingTask: Task<Void, Never>?

    init(channel: LiveChannel, guide: LiveTVGuide?) {
        self.channel = channel
        self.guide = guide
    }

    var api: APIClient? { guide?.context.api }
    var token: String { guide?.context.token ?? "" }
}

/// The player playing a live channel: the stream the channel's source names (an HLS playlist, a bare transport stream mpv
/// opens as it is, or a tuner the server tunes first), with channel up and down (Page Up and Page Down, N, the media keys'
/// Next and Previous), Previous Channel (Backspace) and a channel's number typed on the digits. A banner says which channel
/// and what is on whenever the channel changes.
extension PlayerScreen {
    func startLive() {
        guard let live else { return }
        tune(live.channel)
    }

    /// Plays `channel`, ending the previous one's tuner session first; when it fails, a copy of its station from another
    /// source plays instead, if the guide merged any.
    func tune(_ channel: LiveChannel, failingOver: Bool = false) {
        guard let live else { return }
        if failingOver { live.triedCopies.insert(channel.id) } else { live.triedCopies = [channel.id] }
        let ending = live.plan
        let api = live.api
        let token = live.token
        live.channel = channel
        live.plan = nil
        transport.title = channel.numberedTitle
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            if let ending { await LivePlayback.stop(ending, api: api) }
            do {
                let plan = try await LivePlayback.plan(for: channel, token: token, api: api)
                guard let self, !Task.isCancelled, !self.closed else {
                    await LivePlayback.stop(plan, api: api)
                    return
                }
                self.open(plan, for: channel)
            } catch {
                guard let self, !Task.isCancelled, !self.closed else { return }
                MidgarLog.error("Live channel \(channel.id) failed: \(error)", category: .liveTV)
                if let live = self.live, let next = live.guide?.alternates(of: channel.id).first(where: { !live.triedCopies.contains($0.id) }) {
                    MidgarLog.notice("Trying its copy \(next.id)", category: .liveTV)
                    self.tune(next, failingOver: true)
                    return
                }
                self.presentFailure((error as? LocalizedError)?.errorDescription ?? ConnectionError.message(for: error), retry: { [weak self] in self?.tune(channel) })
            }
        }
    }

    private func open(_ plan: LivePlaybackPlan, for channel: LiveChannel) {
        guard let live, let player else { return }
        live.plan = plan
        stream = ResolvedStream(url: plan.url, isDirectPlay: true, sessionId: "", subtitles: [], audioTracks: [], markers: [])
        segments = []
        streamOffset = 0
        var headers = plan.headers
        if let agent = headers.removeValue(forKey: "User-Agent") { player.set("user-agent", agent) }
        player.set("speed", "1")
        player.set("sid", "no")
        loadTweaks()
        applyDisplay()
        player.load(plan.url, start: 0, headers: headers, options: Self.liveOptions(for: plan))
        player.setPaused(false)
        ScreenAwake.hold(true, in: window)
        live.guide?.watched(channel.id)
        infoPanel?.update(infoContent)
        showBanner(channel)
        MidgarLog.notice("Playing live channel \(channel.id) (\(plan.format == .hls ? "HLS" : "transport stream"))", category: .liveTV)
    }

    /// What mpv is told for a live stream: reconnect when a transport stream drops, as IPTV streams do now and then.
    private static func liveOptions(for plan: LivePlaybackPlan) -> KeyValuePairs<String, String> {
        switch plan.format {
        case .transportStream:
            return ["stream-lavf-o": "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4", "cache": "yes"]
        case .hls:
            return ["cache": "yes"]
        }
    }

    /// Says which channel is on and what airs now.
    private func showBanner(_ channel: LiveChannel) {
        let program = live?.guide?.nowAndNext(channel.id).now
        let line = [channel.numberedTitle, program?.title].compactMap { $0 }.joined(separator: "  ·  ")
        say(line, symbol: "antenna.radiowaves.left.and.right")
    }

    /// Channel up (`offset` 1) or down (-1) in the guide's list.
    func zap(by offset: Int) {
        guard let live, let next = live.guide?.channel(from: live.channel.id, offset: offset), next.id != live.channel.id else { return }
        live.previous = live.channel
        tune(next)
    }

    /// Back to the channel watched before.
    private func previousChannel() {
        guard let live, let previous = live.previous else { return }
        live.previous = live.channel
        tune(previous)
    }

    /// The keys a live channel takes before the player's own: channel up and down, Previous Channel and typed numbers.
    func liveKey(_ event: KeyEvent) -> Bool {
        guard let live else { return false }
        switch event.key {
        case .pageUp, Key.character("n"):
            zap(by: 1)
        case .pageDown:
            zap(by: -1)
        case .backspace:
            previousChannel()
        case .return, .keypadEnter:
            guard !live.typed.isEmpty else { return false }
            goToTypedChannel()
        default:
            guard let digit = event.text.first, digit.isNumber, event.text.count == 1 else { return false }
            live.typed.append(digit)
            say(live.typed)
            live.typingTask?.cancel()
            live.typingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                self?.goToTypedChannel()
            }
        }
        return true
    }

    private func goToTypedChannel() {
        guard let live else { return }
        let number = live.typed
        live.typed = ""
        live.typingTask?.cancel()
        guard let channel = live.guide?.channels.first(where: { $0.number == number }) else {
            say(String(localized: "No channel \(number)", comment: "Player message when a typed live TV channel number does not exist"), symbol: "exclamationmark.circle.fill")
            return
        }
        guard channel.id != live.channel.id else { return }
        live.previous = live.channel
        tune(channel)
    }

    /// Ends the tuner session behind the channel, if any.
    func closeLive() {
        guard let live else { return }
        live.typingTask?.cancel()
        guard let plan = live.plan else { return }
        let api = live.api
        live.plan = nil
        Task { await LivePlayback.stop(plan, api: api) }
    }
}
