import CrucibleCore
import Foundation

/// What Crucible's windows showed when it last ran, so a relaunch opens them again on the same tabs and title pages (the
/// iPad's `WindowActivity`, one per scene): for each window, first window first, its tab and the title on top of it, kept
/// with the server they belong to.
@MainActor
enum WindowRestoration {
    struct State: Equatable {
        var tab: String
        var route: DetailRoute?
    }

    /// A window that can say what it shows.
    @MainActor
    protocol Restorable: AnyObject {
        var restorationState: State? { get }
    }

    private static let key = "linux.windowStates"
    /// One window's state as releases before multiple windows kept it.
    private static let legacyKey = "linux.windowState"

    private final class Tracked {
        weak var window: (any WindowRestoration.Restorable)?
        init(_ window: any WindowRestoration.Restorable) { self.window = window }
    }

    private static var tracked: [Tracked] = []

    /// Starts remembering `window` after the ones already tracked.
    static func track(_ window: any WindowRestoration.Restorable) {
        guard !tracked.contains(where: { $0.window === window }) else { return }
        tracked.append(Tracked(window))
    }

    /// A window was closed on its own: it is no longer reopened.
    static func untrack(_ window: any WindowRestoration.Restorable) {
        tracked.removeAll { $0.window == nil || $0.window === window }
        saveAll()
    }

    /// The session the windows showed ended: none is remembered from here on, and what was saved stays as it is.
    static func untrackAll() {
        tracked.removeAll()
    }

    /// Remembers every open window for the connected server.
    static func saveAll() {
        tracked.removeAll { $0.window == nil }
        let states = tracked.compactMap { $0.window?.restorationState }
        guard !states.isEmpty else { return }
        UserDefaults.standard.set(states.map(encode), forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// What to reopen on the connected server, first window first; empty when the windows showed another server.
    static func restoreAll() -> [State] {
        let stored = (UserDefaults.standard.array(forKey: key) as? [[String: String]])
            ?? (UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String]).map { [$0] } ?? []
        return stored.compactMap(decode)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    private static func encode(_ state: State) -> [String: String] {
        var stored: [String: String] = ["tab": state.tab, "server": ServerBootstrap.savedMachineIdentifier ?? ""]
        switch state.route {
        case .show(let ratingKey, let season)?:
            stored["kind"] = "show"
            stored["ratingKey"] = ratingKey
            stored["season"] = season
        case .item(let ratingKey, let mediaType, let show, let season)?:
            stored["kind"] = "item"
            stored["ratingKey"] = ratingKey
            stored["mediaType"] = mediaType
            stored["show"] = show
            stored["season"] = season
        case nil:
            break
        }
        return stored
    }

    private static func decode(_ stored: [String: String]) -> State? {
        guard let tab = stored["tab"], stored["server"] == ServerBootstrap.savedMachineIdentifier else { return nil }
        var route: DetailRoute?
        if let ratingKey = stored["ratingKey"] {
            switch stored["kind"] {
            case "show": route = .show(ratingKey: ratingKey, initialSeasonKey: stored["season"])
            case "item": route = stored["mediaType"].map { .item(ratingKey: ratingKey, mediaType: $0, showRatingKey: stored["show"], seasonRatingKey: stored["season"]) }
            default: break
            }
        }
        return State(tab: tab, route: route)
    }
}
