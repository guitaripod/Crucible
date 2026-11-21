import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif

/// Instant Start: makes the one title the viewer is most likely to play next ready before they press Play, and hands it
/// to the player that then asks for it.
///
/// A screen calls `warm` when the viewer shows they may play a title (`PlayIntent`): its page opened, focus or a pointer
/// came to rest on its card, a finger went down on it. The title's stream is resolved straight away and, where
/// `WarmStartRule` finds it costs nobody anything, loaded into a paused player at the place playback starts from. A
/// player surface asks `take` for the session before it makes its own; a session it gets has already done the waiting.
///
/// One title is held at a time. Warming another gives the one before it back (its player emptied, its stream on the
/// server stopped), and so do `WarmStartRule.freshness` passing, the app leaving the foreground and the system running
/// short of memory. Nothing here is ever visible: a title that could not be made ready is simply started the usual way.
@MainActor
package final class PlaybackWarmUp {
    package static let shared = PlaybackWarmUp()

    private struct Held {
        let key: WarmKey
        let api: APIClient
        let session: PlaybackSession
        var intent: PlayIntent
        let since: ContinuousClock.Instant
    }

    private var held: Held?
    /// Why the last ask was refused outright, so the log says so once when that changes and not at every ask.
    private var lastRefusal: String?
    /// The title last handed to a player, and that player's session while it lives.
    private var lastPlayed: (ratingKey: String, session: () -> PlaybackSession?)?
    private var work: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    private init() {
        CellularWatch.start()
        #if canImport(UIKit)
        observers = [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cool() }
            }
        }
        #endif
    }

    /// The viewer may be about to play `request`. Asking again for the title already held costs nothing, and a stronger
    /// `intent` for it makes it ready further.
    package func warm(api: APIClient, request: PlaybackRequest, intent: PlayIntent, installsRemoteCommands: Bool = true) {
        guard let key = WarmKey(request) else { return }
        let refusal = conditions.refusal
        if refusal != lastRefusal {
            lastRefusal = refusal
            MidgarLog.notice("Instant Start: \(refusal.map { "holding back, \($0)" } ?? "making titles ready again")", category: .playback)
        }
        guard refusal == nil else {
            cool()
            return
        }
        guard !wasJustPlayed(key.ratingKey) else { return }
        if var current = held, current.key == key, current.api === api, isUsable(current) {
            guard intent > current.intent else { return }
            current.intent = intent
            held = current
            deepen(current.session)
            return
        }
        cool()
        let session = PlaybackSession(api: api, request: request, installsRemoteCommands: installsRemoteCommands)
        held = Held(key: key, api: api, session: session, intent: intent, since: .now)
        MidgarLog.notice("Instant Start: resolving ratingKey=\(request.ratingKey) intent=\(intent)", category: .playback)
        work = Task { [weak self] in
            do {
                _ = try await session.prepare()
            } catch {
                self?.drop(session, because: error)
                return
            }
            self?.deepen(session)
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: WarmStartRule.freshness)
            guard !Task.isCancelled else { return }
            self?.expire(session)
        }
    }

    /// The session made ready for `request`, if there is one, for the player that is about to play it. It is the
    /// caller's from here on. Anything else that was held stays held: it was not what the viewer chose this time.
    package func take(api: APIClient, request: PlaybackRequest) -> PlaybackSession? {
        guard let current = held, let key = WarmKey(request), current.key == key, current.api === api, isUsable(current) else { return nil }
        held = nil
        work = nil
        expiry?.cancel()
        expiry = nil
        current.session.startedFrom = current.session.warmth
        began(current.session)
        MidgarLog.notice("Instant Start: handing over ratingKey=\(request.ratingKey) start=\(current.session.warmth.logName) loaded=\(current.session.isLoaded)", category: .playback)
        return current.session
    }

    /// A player took `session` on, made ready here or not: its title is the one the viewer played last.
    func began(_ session: PlaybackSession) {
        lastPlayed = (session.request.ratingKey, { [weak session] in session })
    }

    /// Gives back whatever is held: the viewer went somewhere it no longer belongs to.
    package func cool() {
        guard let current = held else { return }
        release()
        MidgarLog.notice("Instant Start: letting go of ratingKey=\(current.key.ratingKey)", category: .playback)
        current.session.discard()
    }

    /// Gives back `ratingKey` if that is the title held, for a screen that only speaks for its own title.
    package func cool(ratingKey: String) {
        guard held?.key.ratingKey == ratingKey else { return }
        cool()
    }

    /// Whether `ratingKey` is the title the viewer played last and has looked at nothing else since: it is playing right
    /// now, or they closed it and are back on the screen they started it from, which still shows it. Making it ready
    /// again there would load, for someone who just stopped watching, the very thing they stopped. Any other title made
    /// ready ends this.
    private func wasJustPlayed(_ ratingKey: String) -> Bool {
        guard let last = lastPlayed else { return false }
        guard last.ratingKey == ratingKey else {
            if last.session()?.isSpent != false { lastPlayed = nil }
            return false
        }
        return true
    }

    private func release() {
        held = nil
        work?.cancel()
        work = nil
        expiry?.cancel()
        expiry = nil
    }

    /// Loads the resolved stream as far as the rule allows for the intent shown so far.
    private func deepen(_ session: PlaybackSession) {
        guard let current = held, current.session === session, let stream = session.stream else { return }
        let cost = StreamCost(stream)
        let depth = WarmStartRule.depth(intent: current.intent, cost: cost, conditions: conditions)
        let milliseconds = Int((current.since.duration(to: .now).seconds * 1000).rounded())
        MidgarLog.notice("Instant Start: ratingKey=\(current.key.ratingKey) cost=\(cost) intent=\(current.intent) depth=\(depth.logName) after \(milliseconds) ms", category: .playback)
        if depth == .loaded { session.preload() }
    }

    private func drop(_ session: PlaybackSession, because error: any Error) {
        guard held?.session === session else { return }
        release()
        session.discard()
        guard !(error is CancellationError) else { return }
        MidgarLog.notice("Instant Start: ratingKey=\(session.request.ratingKey) could not be resolved ahead: \(error.localizedDescription)", category: .playback)
    }

    private func expire(_ session: PlaybackSession) {
        guard held?.session === session else { return }
        cool()
    }

    private func isUsable(_ held: Held) -> Bool {
        !held.session.isSpent && held.since.duration(to: .now) < WarmStartRule.freshness
    }

    /// `CRUCIBLE_INSTANT=0` starts a debug build with Instant Start off without touching the setting, so the same device
    /// can be timed both ways.
    private var isSwitchedOffForThisLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CRUCIBLE_INSTANT"] == "0"
        #else
        false
        #endif
    }

    private var conditions: WarmConditions {
        let process = ProcessInfo.processInfo
        return WarmConditions(
            isEnabled: Preferences.instantStart && !isSwitchedOffForThisLaunch,
            isCellular: NetworkConditions.isCellular,
            savesPower: process.isLowPowerModeEnabled,
            isHot: process.thermalState == .serious || process.thermalState == .critical,
            isPlaying: PlaybackSession.isAnyPlaying
        )
    }
}
