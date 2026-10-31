import CrucibleCore
import CrucibleDemo
import CrucibleStore
import CrucibleTV
import UIKit

@main
enum Entry {
    static func main() {
        installStore()
        installDemo()
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(TVAppDelegate.self)
        )
    }

    /// The App Store build sells Crucible Pro through MidgarStore, and the store must be in place before the first screen. Debug runs
    /// against the mock server or the UI tests never reach the App Store: they stay unlocked, or take the scripted store that
    /// `CRUCIBLE_PRO` asks for.
    private static func installStore() {
        guard sellsThroughAppStore, MidgarProAccess.reachesMidgarServices else { return }
        CrucibleLog.configure()
        MainActor.assumeIsolated {
            ProAccess.shared.install(MidgarProAccess.live())
        }
    }

    /// Offers the demo on the Welcome screen: the fictional library served from inside the app. A debug build that names a running
    /// mock server in `CRUCIBLE_DEMO_URL` signs in to that server instead, so the demo screens can be built without the library.
    private static func installDemo() {
        MainActor.assumeIsolated {
            #if DEBUG
            if let mock = DemoMockProvider() {
                DemoMode.shared.install(mock)
                return
            }
            #endif
            DemoMode.shared.install(DemoLibraryProvider())
        }
    }

    private static var sellsThroughAppStore: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["CRUCIBLE_MOCK"] == nil && environment["CRUCIBLE_UITEST"] == nil && environment["CRUCIBLE_PRO"] == nil
        #else
        return true
        #endif
    }
}
