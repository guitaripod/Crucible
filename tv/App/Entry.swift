import CrucibleCore
import CrucibleStore
import CrucibleTV
import UIKit

@main
enum Entry {
    static func main() {
        installStore()
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(TVAppDelegate.self)
        )
    }

    /// The App Store build sells Crucible Pro through RevenueCat, and the store must be in place before the first screen. Debug runs
    /// against the mock server or the UI tests never reach the App Store: they stay unlocked, or take the scripted store that
    /// `CRUCIBLE_PRO` asks for.
    private static func installStore() {
        guard sellsThroughAppStore else { return }
        RevenueCatProAccess.configure(apiKey: StoreSecrets.revenueCatPublicKey)
        MainActor.assumeIsolated {
            ProAccess.shared.install(RevenueCatProAccess())
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
