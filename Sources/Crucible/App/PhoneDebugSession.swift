import Foundation
#if DEBUG
import CrucibleCore
import MidgarCore
#endif

/// Launch-time switches for simulator runs and UI tests. Everything that changes the session only exists in DEBUG builds.
enum PhoneDebugSession {
    #if DEBUG
    /// With `CRUCIBLE_FRESH=1` first forgets the account, the server, the demo and its tour, so every launch starts as a new install.
    @MainActor
    static func bootstrapIfRequested() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_FRESH"] == "1" else { return }
        AccountSessionReset.signOut(.phone)
        forgetDemo()
        MidgarLog.notice("Debug session: fresh install state", category: .lifecycle)
    }

    /// With `CRUCIBLE_DEMO_DONE="play,browse,statistics"` marks those tour steps done. Called once the demo session has begun, because
    /// beginning it starts a new tour.
    @MainActor
    static func seedDemoTourIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["CRUCIBLE_DEMO_DONE"] else { return }
        let steps = raw.split(separator: ",").compactMap { DemoTourStep(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        for step in steps { DemoTour.shared.record(step, demoActive: true) }
        MidgarLog.notice("Debug session: demo tour steps pre-completed: \(steps.map(\.rawValue))", category: .lifecycle)
    }

    /// A fresh install is not in the demo: its flag, tour and welcome sheet are forgotten.
    @MainActor
    private static func forgetDemo() {
        UserDefaults.standard.removeObject(forKey: DemoMode.activeKey)
        DemoTour.shared.reset()
        DemoPhoneSession.shared.endSession()
    }
    #endif
}
