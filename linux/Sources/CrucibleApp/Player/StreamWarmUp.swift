import CrucibleCore
import Foundation
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

/// Instant Start on the desk and the Deck: the stream of the one title the viewer is most likely to play next is resolved
/// before they press Play, so the player that opens hands it to mpv at once instead of asking the server first. A screen
/// calls `warm` when the viewer shows they may play a title (its page is open, focus or the pointer came to rest on its
/// card); the player asks `take`. One title is held at a time and for no longer than `WarmStartRule.freshness`; resolving
/// costs the server nothing to keep, so a title nobody played is simply forgotten.
@MainActor
final class StreamWarmUp {
    static let shared = StreamWarmUp()

    private struct Held {
        let plan: FirstStreamPlan
        let api: APIClient
        let stream: Task<ResolvedStream, any Error>
        let since: ContinuousClock.Instant
    }

    private var held: Held?

    /// The viewer may be about to play `item` from `resume` (where the server has it by default) in `tracks`.
    func warm(api: APIClient, item: PlexMetadata, resume: Double? = nil, tracks: (audio: Int?, subtitle: Int?)? = nil) {
        guard WarmStartRule.allows(WarmConditions(isEnabled: Preferences.instantStart)), HomeMediaRules.isPlayable(item) else {
            cool()
            return
        }
        let start = resume ?? item.resumeSecs
        let plan = FirstStreamPlan(item: item, resume: start, tracks: tracks, carried: nil)
        if let held, held.plan == plan, held.api === api, isFresh(held) { return }
        cool()
        MidgarLog.notice("Instant Start: resolving ratingKey=\(item.id)", category: .playback)
        held = Held(plan: plan, api: api, stream: Task { try await plan.resolve(api: api, startSecs: start) }, since: .now)
    }

    /// The stream being resolved, or already resolved, for `plan`, for the player that is about to play it.
    func take(_ plan: FirstStreamPlan, api: APIClient) -> Task<ResolvedStream, any Error>? {
        guard let held, held.plan == plan, held.api === api, isFresh(held) else { return nil }
        self.held = nil
        return held.stream
    }

    /// Forgets what is held, or only `ratingKey` when that is given and held.
    func cool(ratingKey: String? = nil) {
        guard let held, ratingKey == nil || held.plan.ratingKey == ratingKey else { return }
        held.stream.cancel()
        self.held = nil
    }

    /// Follows focus or the pointer across cards for a screen: where it stops is what the viewer is thinking of playing.
    static func restWatch() -> RestWatch {
        RestWatch { shared.cool(ratingKey: $0) }
    }

    private func isFresh(_ held: Held) -> Bool {
        held.since.duration(to: .now) < WarmStartRule.freshness
    }
}
