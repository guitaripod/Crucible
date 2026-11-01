import CrucibleCore
import CrucibleDemo
import CrucibleStore
import MidgarCommerce
import UIKit

@main
enum Entry {
    @MainActor
    static func main() {
        CrucibleLog.configure()
        if MidgarProAccess.reachesMidgarServices {
            ProAccess.shared.install(MidgarProAccess.live())
            installPlaybackOffer()
        }
        DemoMode.shared.install(demoProvider())
        _ = UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }

    /// Gives the player MidgarKit's offer policy: Pro is offered after the third item watched to the end, then after
    /// every fifth.
    @MainActor
    private static func installPlaybackOffer() {
        let policy = MidgarOfferPolicy(appID: MidgarProAccess.appID, firstOfferAfter: 3, laterOfferEvery: 5)
        PlaybackOffer.noteValue = { isOwned in policy.noteValue(isOwned: isOwned) }
        PlaybackOffer.noteOffered = { policy.noteOffered() }
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
