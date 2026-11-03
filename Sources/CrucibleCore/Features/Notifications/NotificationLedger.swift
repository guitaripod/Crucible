import Foundation

/// What has already been announced, so a notification is sent once: the reason each rating reminder was sent for, the
/// episodes and watchlist titles announced, and how far back the last check for new arrivals looked. It belongs to one
/// server and is forgotten with everything else bound to it.
@MainActor
package final class NotificationLedger {
    package static let shared = NotificationLedger(defaults: .standard)

    private struct State: Codable {
        var server: String?
        var remindedAsks: [String: String] = [:]
        var announced: [String: Int] = [:]
        var checkedUpTo: Int?
    }

    package static let storageKey = "notificationLedger.v1"
    static let keepAnnounced = 400

    private let defaults: UserDefaults
    private var state: State

    package init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    /// The asks a reminder is due for: new ones and ones whose reason moved on (a show whose next season ended).
    package func asksNeedingReminders(_ asks: [RatingAsk], server: String?) -> [RatingAsk] {
        adopt(server)
        return asks.filter { state.remindedAsks[$0.ratingKey] != $0.reason.key }
    }

    package func noteReminded(_ ask: RatingAsk) {
        state.remindedAsks[ask.ratingKey] = ask.reason.key
        save()
    }

    /// The point in time the next check for arrivals looks back to; the first check starts now, so nothing old is announced.
    package func checkWindowStart(server: String?, now: Date) -> Int {
        adopt(server)
        if let checked = state.checkedUpTo { return checked }
        let start = Int(now.timeIntervalSince1970)
        state.checkedUpTo = start
        save()
        return start
    }

    package func noteChecked(upTo addedAt: Int) {
        state.checkedUpTo = max(state.checkedUpTo ?? 0, addedAt)
        save()
    }

    package func wasAnnounced(_ key: String) -> Bool {
        state.announced[key] != nil
    }

    package var announcedKeys: Set<String> { Set(state.announced.keys) }

    package func noteAnnounced(_ keys: [String], at date: Date = Date()) {
        let stamp = Int(date.timeIntervalSince1970)
        for key in keys { state.announced[key] = stamp }
        if state.announced.count > Self.keepAnnounced {
            let kept = state.announced.sorted { $0.value > $1.value }.prefix(Self.keepAnnounced)
            state.announced = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        save()
    }

    package func reset() {
        state = State()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func adopt(_ server: String?) {
        guard let server, state.server != server else { return }
        if state.server != nil { state = State() }
        state.server = server
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
