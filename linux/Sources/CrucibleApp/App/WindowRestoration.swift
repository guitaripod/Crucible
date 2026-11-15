import CrucibleCore
import Foundation

/// What the window showed when Crucible last ran, so a relaunch opens on the same tab and title page (the iPad's
/// `WindowActivity`): the tab, the title on top of it when there was one, and the server both belong to.
@MainActor
enum WindowRestoration {
    struct State: Equatable {
        var tab: String
        var route: DetailRoute?
    }

    private static let key = "linux.windowState"

    /// Remembers `state` for the connected server.
    static func save(_ state: State) {
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
        UserDefaults.standard.set(stored, forKey: key)
    }

    /// What to reopen on the connected server, or nil when the window last showed another server or nothing was kept.
    static func restore() -> State? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String], let tab = stored["tab"],
              stored["server"] == ServerBootstrap.savedMachineIdentifier else { return nil }
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

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
