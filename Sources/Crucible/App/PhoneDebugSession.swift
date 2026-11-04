import Foundation
#if DEBUG
import CrucibleCore
import MidgarCore
#endif

/// Launch-time switches for simulator runs and UI tests. Everything that changes the session only exists in DEBUG builds.
enum PhoneDebugSession {
    #if DEBUG
    private static let mockMachineIdentifier = "9c1f0e2a7b3d4e5f8a6b1c2d3e4f5a6b"

    /// With `CRUCIBLE_FRESH=1` first forgets the account, the server, the demo and its tour, so every launch starts as a new install.
    /// With `CRUCIBLE_PHONE_MOCK=<url>` then signs in to the mock Plex server as Marcus, the way the Apple TV tests do, for what the
    /// built-in demo cannot show (a Plex Home); `CRUCIBLE_PLEXTV` points plex.tv at the same mock.
    @MainActor
    static func bootstrapIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if environment["CRUCIBLE_FRESH"] == "1" {
            AccountSessionReset.signOut(.phone)
            forgetDemo()
            MidgarLog.notice("Debug session: fresh install state", category: .lifecycle)
        }
        if let value = environment["CRUCIBLE_PHONE_MOCK"], let base = URL(string: value) {
            forgetDemo()
            ServerBootstrap.clear()
            ServerBootstrap.saveToken("mock-token")
            ServerBootstrap.saveServer(uri: base, name: "Marcus-PC", machineIdentifier: mockMachineIdentifier)
            UserDefaults.standard.set("Marcus", forKey: "plex_account_name")
            MidgarLog.notice("Debug session: mock connection \(base.absoluteString)", category: .lifecycle)
        }
        FinishedTitlesLedger.shared.seedFromEnvironment()
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

    /// A fresh install is not in the demo: its flag, tour, welcome sheet and the watch state the demo library saved are forgotten.
    @MainActor
    private static func forgetDemo() {
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("CrucibleDemo", isDirectory: true))
        }
        UserDefaults.standard.removeObject(forKey: DemoMode.activeKey)
        DemoTour.shared.reset()
        DemoPhoneSession.shared.endSession()
    }
    #endif
}
