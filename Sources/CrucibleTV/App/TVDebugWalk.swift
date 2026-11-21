#if DEBUG
import CrucibleCore
import MidgarCore
import UIKit

/// Presses the remote on a real Apple TV with no hand on it, where nothing else can: `CRUCIBLE_WALK="8:land,12:select,20:close"`
/// runs each step that many seconds after the main screen appears. `land` has focus come to rest on the first Continue
/// Watching card, `select` clicks that card, and `close` ends the player. With the log's "ms after Play" lines these time a start; `CRUCIBLE_INSTANT=0` times it without
/// Instant Start. A step that cannot run where the walk stands says so in the log.
@MainActor
enum TVDebugWalk {
    static func startIfRequested(on tabBar: TVRootTabBarController) {
        guard let script = ProcessInfo.processInfo.environment["CRUCIBLE_WALK"] else { return }
        for step in script.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let delay = TimeInterval(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let action = parts[1].trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tabBar] in
                guard let tabBar else { return }
                let ran = run(action, on: tabBar)
                MidgarLog.notice("Debug walk: \(action)\(ran ? "" : " could not run here")", category: .lifecycle)
            }
        }
    }

    private static func home(of tabBar: TVRootTabBarController) -> TVHomeViewController? {
        tabBar.showHome().viewControllers.lazy.compactMap { $0 as? TVHomeViewController }.first
    }

    private static func run(_ action: String, on tabBar: TVRootTabBarController) -> Bool {
        switch action {
        case "land":
            guard let home = home(of: tabBar) else { return false }
            return home.landOnFirstCard()
        case "select":
            guard let home = home(of: tabBar) else { return false }
            return home.selectFirstCard()
        case "close":
            Task { await TVPlayerCoordinator.endActive() }
            return true
        default:
            return false
        }
    }
}
#endif
