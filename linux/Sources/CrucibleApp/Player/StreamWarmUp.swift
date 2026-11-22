import CrucibleCore
import Foundation
import Kiln
import MidgarCore

/// What the first stream of a title is resolved with: the tracks a title page chose, else the languages the episode before
/// or the show last played in, else what the server and the viewer's settings pick. Two plans that are equal resolve to
/// the same stream, which is what lets one made ahead of Play stand in for the one Play asks for.
struct FirstStreamPlan: Equatable {
    let ratingKey: String
    let startSecond: Int
    let audioID: Int?
    let subtitleID: Int?
    let picksTracks: Bool
    let languages: TrackLanguages?

    /// `carried` is the languages the episode before played in, when this title follows one.
    init(item: PlexMetadata, resume: Double, tracks: (audio: Int?, subtitle: Int?)?, carried: TrackLanguages?) {
        ratingKey = item.id
        startSecond = Int(resume.rounded())
        audioID = tracks?.audio
        subtitleID = tracks?.subtitle
        picksTracks = tracks != nil
        let remembered = item.mediaType == "episode"
            ? ShowTrackMemory.languages(forShow: item.grandparentRatingKey, server: ServerBootstrap.savedMachineIdentifier ?? "unknown")
            : nil
        languages = tracks == nil ? carried ?? remembered : nil
    }

    func resolve(api: APIClient, startSecs: Double, forceTranscode: Bool = false) async throws -> ResolvedStream {
        try await StreamResolver.resolve(
            api: api,
            ratingKey: ratingKey,
            startSecs: startSecs,
            selectedSubtitleId: subtitleID,
            selectedAudioStreamId: audioID,
            languages: languages,
            honorsServerSelection: !picksTracks && languages == nil,
            forceTranscode: forceTranscode
        )
    }
}

/// Instant Start on the desk and the Deck: the one title the viewer is most likely to play next is made ready before they
/// press Play. A screen calls `warm` when the viewer shows they may play a title (its page is open, focus or the pointer
/// came to rest on its card); its stream is resolved straight away and, for a file that plays as it is with nothing else
/// playing, opened in a paused mpv of its own at the place playback starts from, which on a Steam Deck over Wi-Fi is the
/// three seconds a start otherwise spends after Play. The player that opens asks `take` and plays that mpv instead of
/// making one. One title is held at a time and for no longer than `WarmStartRule.freshness`; a title nobody played has its
/// mpv shut down when another is made ready, when focus moves off it or when its time is up.
@MainActor
final class StreamWarmUp {
    static let shared = StreamWarmUp()

    /// What a player takes over: the stream, resolved or still resolving, and the mpv that has opened it, if one has.
    struct Ready {
        let stream: Task<ResolvedStream, any Error>
        let player: VideoPlayer?
        /// The address and second `player` opened, so the screen can tell it is the file it is about to play.
        let file: (url: URL, start: Double)?
        /// Whether `player` had finished opening the file when it was handed over.
        let hasLoaded: Bool
    }

    private final class Held {
        let plan: FirstStreamPlan
        let api: APIClient
        let stream: Task<ResolvedStream, any Error>
        let since = ContinuousClock.now
        var player: VideoPlayer?
        var file: (url: URL, start: Double)?
        var hasLoaded = false
        /// mpv's own limit on what it reads ahead, put back when the player is taken over.
        var readAhead: String?

        init(plan: FirstStreamPlan, api: APIClient, stream: Task<ResolvedStream, any Error>) {
            self.plan = plan
            self.api = api
            self.stream = stream
        }
    }

    /// How much of a file a paused mpv may read ahead of Play: enough to start without a stall, little enough to throw away.
    private static let readAhead = "\(32 * 1024 * 1024)"

    /// The setting, unless `CRUCIBLE_INSTANT=0` starts the app without Instant Start, which is how a Deck is timed both ways.
    private static var isEnabled: Bool {
        Preferences.instantStart && ProcessInfo.processInfo.environment["CRUCIBLE_INSTANT"] != "0"
    }

    private var held: Held?
    private var expiry: Task<Void, Never>?

    /// The viewer may be about to play `item` from `resume` (where the server has it by default) in `tracks`. `window` is
    /// where a player would open, which an mpv made ahead needs to draw into; without one the stream is only resolved.
    func warm(api: APIClient, item: PlexMetadata, resume: Double? = nil, tracks: (audio: Int?, subtitle: Int?)? = nil, in window: Window?) {
        guard WarmStartRule.allows(WarmConditions(isEnabled: Self.isEnabled)), HomeMediaRules.isPlayable(item) else {
            cool()
            return
        }
        let start = resume ?? item.resumeSecs
        let plan = FirstStreamPlan(item: item, resume: start, tracks: tracks, carried: nil)
        if let held, held.plan == plan, held.api === api, isFresh(held) {
            openWhenResolved(held, at: start, in: window)
            return
        }
        cool()
        MidgarLog.notice("Instant Start: resolving ratingKey=\(item.id)", category: .playback)
        let entry = Held(plan: plan, api: api, stream: Task { try await plan.resolve(api: api, startSecs: start) })
        held = entry
        openWhenResolved(entry, at: start, in: window)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: WarmStartRule.freshness)
            guard !Task.isCancelled, self?.held === entry else { return }
            self?.cool()
        }
    }

    /// Opens the file once its stream is resolved. A screen that asked before it had a window asks again when it has one.
    private func openWhenResolved(_ entry: Held, at start: Double, in window: Window?) {
        guard entry.player == nil, let window else { return }
        Task { [weak self, weak window] in
            do {
                let resolved = try await entry.stream.value
                guard let window else { return }
                self?.open(resolved, at: start, for: entry, in: window)
            } catch {
                guard !(error is CancellationError) else { return }
                MidgarLog.notice("Instant Start: ratingKey=\(entry.plan.ratingKey) could not be resolved ahead: \(error)", category: .playback)
            }
        }
    }

    /// Opens the resolved file in a paused mpv, where `WarmStartRule` finds that costs nobody anything.
    private func open(_ resolved: ResolvedStream, at start: Double, for entry: Held, in window: Window) {
        guard held === entry, entry.player == nil else { return }
        let conditions = WarmConditions(isEnabled: Self.isEnabled, isPlaying: PlayerScreen.active != nil)
        let cost = StreamCost(resolved)
        let depth = resolved.isDirectPlay ? WarmStartRule.depth(intent: .poised, cost: cost, conditions: conditions) : .resolved
        MidgarLog.notice("Instant Start: ratingKey=\(entry.plan.ratingKey) cost=\(cost) depth=\(depth.logName)", category: .playback)
        guard depth == .loaded, let loop = window.loop else { return }
        let player: VideoPlayer
        do {
            player = try VideoPlayer(gpu: window.gpu, loop: loop)
        } catch {
            MidgarLog.error("Instant Start: no player for ratingKey=\(entry.plan.ratingKey): \(error)", category: .playback)
            return
        }
        let opensAt = PlayerScreen.streamStart(of: resolved, at: start)
        let began = ContinuousClock.now
        entry.readAhead = player.get("demuxer-max-bytes")
        player.set("demuxer-max-bytes", Self.readAhead)
        player.setPaused(true)
        player.onEvent = { [weak self, weak entry] event in
            guard let entry else { return }
            switch event {
            case .loaded:
                entry.hasLoaded = true
                let elapsed = began.duration(to: .now).components
                let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
                MidgarLog.notice("Instant Start: ratingKey=\(entry.plan.ratingKey) loaded in \(milliseconds) ms", category: .playback)
            case .failed:
                if self?.held === entry { self?.cool() }
            case .seeked, .ended:
                break
            }
        }
        player.load(resolved.url, start: opensAt, headers: PlexHeaders.allHeaders(token: entry.api.token), options: FileTracks(resolved).loadOptions)
        entry.player = player
        entry.file = (resolved.url, opensAt)
    }

    /// What was made ready for `plan`, for the player that is about to play it; it is the caller's from here on.
    func take(_ plan: FirstStreamPlan, api: APIClient) -> Ready? {
        guard let held, held.plan == plan, held.api === api, isFresh(held) else { return nil }
        self.held = nil
        expiry?.cancel()
        held.player?.onEvent = nil
        if let player = held.player, let readAhead = held.readAhead { player.set("demuxer-max-bytes", readAhead) }
        return Ready(stream: held.stream, player: held.player, file: held.file, hasLoaded: held.hasLoaded)
    }

    /// Forgets what is held, or only `ratingKey` when that is given and held, and shuts its mpv down.
    func cool(ratingKey: String? = nil) {
        guard let held, ratingKey == nil || held.plan.ratingKey == ratingKey else { return }
        self.held = nil
        expiry?.cancel()
        held.stream.cancel()
        held.player?.onEvent = nil
        held.player?.shutDown()
    }

    /// Follows focus or the pointer across cards for a screen: where it stops is what the viewer is thinking of playing.
    static func restWatch() -> RestWatch {
        RestWatch { shared.cool(ratingKey: $0) }
    }

    private func isFresh(_ held: Held) -> Bool {
        held.since.duration(to: .now) < WarmStartRule.freshness
    }
}

extension PlayerScreen {
    /// Takes over what Instant Start made ready for the title this screen plays, and returns the mpv that already has its
    /// file open, when there is one. Not for a start that follows a failure, which wants a fresh look at everything. Anything
    /// it made ready for another title is let go: on a Steam Deck whose Wi-Fi had slowed to a crawl, the first episode a
    /// show's page made ready went on loading for 19 s beside the one the viewer played, which took 10 s to show.
    func takeWarmPlayer() -> VideoPlayer? {
        guard case .plex(let api, let item, let resumePosition) = source, !convertsAfterFailure else {
            StreamWarmUp.shared.cool()
            return nil
        }
        let plan = FirstStreamPlan(item: item, resume: resumePosition, tracks: chosenTracks, carried: run.trackLanguages)
        warm = StreamWarmUp.shared.take(plan, api: api)
        if warm == nil { StreamWarmUp.shared.cool() }
        startedFrom = warm == nil ? .none : warm?.player == nil ? .resolved : .loaded
        return warm?.player
    }

    /// Whether the mpv this screen took over already has `url` open at `start`, so it only has to be played. The tracks of a
    /// file that had finished opening are settled here, since the word that it opened came before this screen was listening.
    func adoptsWarmFile(_ url: URL, start: Double) -> Bool {
        defer { warm = nil }
        guard let warm, let file = warm.file, file.url == url, abs(file.start - start) < 0.5, let player else { return false }
        if warm.hasLoaded { settleFileTracks() }
        stateChanged(player.state)
        return true
    }
}
