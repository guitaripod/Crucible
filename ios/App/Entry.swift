import CrucibleCore
import CrucibleDemo
import CrucibleStore
import UIKit

@main
enum Entry {
    @MainActor
    static func main() {
        RevenueCatProAccess.configure(apiKey: StoreSecrets.revenueCatPublicKey)
        ProAccess.shared.install(RevenueCatProAccess())
        DemoMode.shared.install(demoProvider())
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }

    /// The fictional library the welcome screen offers. A debug build can point it at a running mock server instead, to build screens
    /// without the in-app library.
    private static func demoProvider() -> any DemoProviding {
        #if DEBUG
        if let mock = DemoMockProvider() { return mock }
        #endif
        return DemoLibraryProvider()
    }
}
