import Foundation
#if DEBUG
import CrucibleCore
import UIKit
#endif

/// Launch-time switches for simulator runs and UI tests. Everything that changes the session only
/// exists in DEBUG builds.
enum TVDebugSession {
    /// True under `CRUCIBLE_UITEST=1`: endless decorative animations stay off so XCUITest can
    /// reach idle.
    static var disablesAmbientAnimation: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CRUCIBLE_UITEST"] == "1"
        #else
        false
        #endif
    }

    #if DEBUG
    /// With `CRUCIBLE_STYLE=light|dark` pins the window's appearance: the tvOS simulator cannot be
    /// switched with `simctl ui appearance`, so this is how screens are checked in Light.
    @MainActor
    static func applyAppearance(to window: UIWindow) {
        switch ProcessInfo.processInfo.environment["CRUCIBLE_STYLE"] {
        case "light": window.overrideUserInterfaceStyle = .light
        case "dark": window.overrideUserInterfaceStyle = .dark
        default: break
        }
    }

    private static let mockMachineIdentifier = "9c1f0e2a7b3d4e5f8a6b1c2d3e4f5a6b"

    /// With `CRUCIBLE_MOCK=<url>` replaces the stored connection with the mock Plex server, signed
    /// in as Marcus, exactly like the marketing capture harness. The real launch pipeline then
    /// runs against it.
    static func bootstrapIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["CRUCIBLE_MOCK"], let base = URL(string: value) else { return }
        ServerBootstrap.clear()
        ServerBootstrap.saveToken("mock-token")
        ServerBootstrap.saveServer(uri: base, name: "Marcus-PC", machineIdentifier: mockMachineIdentifier)
        UserDefaults.standard.set("Marcus", forKey: "plex_account_name")
        AppLogger.notice("Debug session: mock connection \(base.absoluteString)", .lifecycle)
    }
    #endif
}
