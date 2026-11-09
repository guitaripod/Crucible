import CrucibleCore
import Foundation

/// The Statistics source the viewer last chose, kept on the device: Everything once chosen stays chosen while Trakt is
/// connected and Pro is on, and Plex otherwise.
@MainActor
package enum StatsSourceChoice {
    private static let key = "stats.source"

    package static func initial() -> StatsSource {
        guard StatsManager.shared.offersEverything, ProAccess.shared.hasFullAccess else { return .plex }
        return UserDefaults.standard.string(forKey: key).flatMap(StatsSource.init(rawValue:)) ?? .everything
    }

    package static func remember(_ source: StatsSource) {
        UserDefaults.standard.set(source.rawValue, forKey: key)
    }
}
