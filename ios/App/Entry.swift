import CrucibleCore
import CrucibleStore
import UIKit

@main
enum Entry {
    @MainActor
    static func main() {
        RevenueCatProAccess.configure(apiKey: StoreSecrets.revenueCatPublicKey)
        ProAccess.shared.install(RevenueCatProAccess())
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }
}
