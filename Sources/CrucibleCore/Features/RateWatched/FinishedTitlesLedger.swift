import Foundation
import MidgarCore

/// What the viewer finished on this device and what became of asking them about it: titles they rated, titles they waved
/// away, and when the server was last asked whether a title is already rated. It belongs to one server; finishing something
/// on another server starts it over, and `AccountSessionReset` forgets it with everything else bound to a server.
@MainActor
package final class FinishedTitlesLedger {
    package static let shared = FinishedTitlesLedger(defaults: .standard)

    private struct State: Codable {
        var server: String?
        var titles: [FinishedTitle] = []
        var rated: [String: Date] = [:]
        var dismissed: [String: Date] = [:]
        var checked: [String: Date] = [:]
        var posters: [String: String]? = nil
        var sections: [String: Int]? = nil
    }

    package static let storageKey = "finishedTitles.v1"
    static let keep = 80
    static let keepFor: TimeInterval = 90 * 86_400
    static let checkEvery: TimeInterval = 12 * 3_600

    private let defaults: UserDefaults
    private var state: State
    private var observers: [UUID: @MainActor () -> Void] = [:]

    package init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    package var titles: [FinishedTitle] { state.titles }

    /// Notes a finished movie or episode for `server`, newest first, keeping one entry per title.
    package func record(_ title: FinishedTitle, server: String?) {
        adopt(server)
        state.titles.removeAll { $0.ratingKey == title.ratingKey }
        state.titles.insert(title, at: 0)
        prune(now: title.finishedAt)
        MidgarLog.info("Finished \(title.kind.rawValue) ratingKey=\(title.ratingKey) endedShow=\(title.endedShow) endedSeason=\(title.endedSeason)", category: .playback)
        changed()
    }

    /// The viewer rated (or cleared the rating of) `ratingKey` somewhere in the app.
    package func noteRated(_ ratingKey: String, isRated: Bool, at date: Date = Date()) {
        if isRated {
            guard state.rated[ratingKey] == nil else { return }
            state.rated[ratingKey] = date
        } else {
            guard state.rated.removeValue(forKey: ratingKey) != nil else { return }
            state.dismissed[ratingKey] = date
        }
        changed()
    }

    /// "Not Now": the title leaves the row until something of it is finished again.
    package func dismiss(_ ratingKey: String, at date: Date = Date()) {
        state.dismissed[ratingKey] = date
        changed()
    }

    /// Whether the server should be asked again whether `ratingKey` is rated: twelve hours after the last time, or at once
    /// while its library is unknown, so a title from a library the viewer leaves out drops out of the asks soon.
    package func needsCheck(_ ratingKey: String, now: Date) -> Bool {
        guard let checked = state.checked[ratingKey], section(of: ratingKey) != nil else { return true }
        return now.timeIntervalSince(checked) >= Self.checkEvery
    }

    /// The server was asked about `ratingKey`: it is not rated yet, `poster` is its own artwork and `section` its library.
    /// Learning a title's library tells observers, since it can take the title out of the asks.
    package func noteChecked(_ ratingKey: String, at date: Date, poster: String? = nil, section: Int? = nil) {
        state.checked[ratingKey] = date
        if let poster { state.posters = (state.posters ?? [:]).merging([ratingKey: poster]) { _, new in new } }
        let learned = section != nil && state.sections?[ratingKey] != section
        if let section { state.sections = (state.sections ?? [:]).merging([ratingKey: section]) { _, new in new } }
        if learned { changed() } else { save() }
    }

    /// The titles to ask about on the server the app is connected to, none of them from the `excluded` libraries.
    package func asks(now: Date, server: String?, excluding excluded: Set<Int> = LibraryVisibility.excluded) -> [RatingAsk] {
        guard server == nil || state.server == nil || state.server == server else { return [] }
        return RatingAskRule.asks(from: shown(state.titles, excluding: excluded), rated: Set(state.rated.keys), dismissed: state.dismissed, posters: state.posters ?? [:], now: now)
    }

    /// Shows the viewer finished an episode of since `since`, newest first, for news about them, none of them from the
    /// `excluded` libraries.
    package func followedShows(since: Date, excluding excluded: Set<Int> = LibraryVisibility.excluded) -> [FinishedTitle] {
        var seen = Set<String>()
        return shown(state.titles, excluding: excluded).filter { title in
            guard title.kind == .episode, title.finishedAt >= since, let show = title.showRatingKey else { return false }
            return seen.insert(show).inserted
        }
    }

    /// The library `ratingKey` belongs to, from a title finished in it or from the server's answer about it.
    private func section(of ratingKey: String) -> Int? {
        state.sections?[ratingKey] ?? state.titles.first { $0.ratedKey == ratingKey && $0.librarySectionID != nil }?.librarySectionID
    }

    private func shown(_ titles: [FinishedTitle], excluding excluded: Set<Int>) -> [FinishedTitle] {
        guard !excluded.isEmpty else { return titles }
        return titles.filter { title in
            LibraryVisibility.shows(section: title.librarySectionID ?? title.ratedKey.flatMap { state.sections?[$0] }, excluding: excluded)
        }
    }

    package func reset() {
        state = State()
        defaults.removeObject(forKey: Self.storageKey)
        notify()
    }

    @discardableResult
    package func addObserver(_ block: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    package func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func adopt(_ server: String?) {
        guard let server, state.server != server else { return }
        if state.server != nil { state = State() }
        state.server = server
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keepFor)
        state.titles = Array(state.titles.filter { $0.finishedAt >= cutoff }.prefix(Self.keep))
        let kept = Set(state.titles.map(\.ratingKey) + state.titles.compactMap(\.showRatingKey))
        state.checked = state.checked.filter { kept.contains($0.key) }
        state.dismissed = state.dismissed.filter { kept.contains($0.key) }
        state.rated = state.rated.filter { kept.contains($0.key) }
        state.posters = state.posters?.filter { kept.contains($0.key) }
        state.sections = state.sections?.filter { kept.contains($0.key) }
    }

    private func changed() {
        save()
        notify()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func notify() {
        for observer in observers.values { observer() }
    }
}

#if DEBUG
extension FinishedTitlesLedger {
    /// With `CRUCIBLE_FINISHED="m:1001:Title,s:2001:Show:4005"` records finished titles for UI tests: `m` a movie, `s` a show
    /// whose episode `4005` caught the viewer up. Starts from an empty ledger that is not tied to a server yet, so the demo or
    /// the mock adopts it whenever it connects.
    package func seedFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) {
        guard let raw = environment["CRUCIBLE_FINISHED"] else { return }
        reset()
        let server: String? = nil
        for (offset, entry) in raw.split(separator: ",").enumerated() {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let finishedAt = now.addingTimeInterval(-Double(offset + 1) * 60)
            switch parts.first {
            case "m" where parts.count >= 3:
                record(FinishedTitle(ratingKey: parts[1], kind: .movie, title: parts[2], finishedAt: finishedAt), server: server)
            case "s" where parts.count >= 4:
                record(FinishedTitle(
                    ratingKey: parts[3],
                    kind: .episode,
                    title: parts[2],
                    showTitle: parts[2],
                    showRatingKey: parts[1],
                    finishedAt: finishedAt,
                    endedShow: true
                ), server: server)
            default:
                continue
            }
        }
    }
}
#endif
