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
        #if DEBUG
        installScriptedOfferPolicy()
        installLiveModelIfRequested()
        #endif
        guard sellsThroughAppStore, MidgarProAccess.reachesMidgarServices else { return }
        CrucibleLog.configure()
        MainActor.assumeIsolated {
            MidgarServices.live().install()
            MidgarProAccess.installPlaybackOffer(
                firstOfferAfter: 1, laterOfferEvery: 5, alreadyOffered: ProMomentLedger().hasShown(.firstFinish))
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

    #if DEBUG
    /// A run on the scripted store (`CRUCIBLE_PRO`) counts finished videos with the policy the App Store build uses, from nothing
    /// when `CRUCIBLE_FRESH=1` makes it a new install, so the note after a finished video shows up in UI tests as it does for real.
    private static func installScriptedOfferPolicy() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CRUCIBLE_PRO"] != nil else { return }
        MainActor.assumeIsolated {
            if environment["CRUCIBLE_FRESH"] == "1" { MidgarProAccess.forgetPlaybackOfferForTesting() }
            MidgarProAccess.installPlaybackOffer(firstOfferAfter: 1, laterOfferEvery: 5)
        }
    }
    #endif

    #if DEBUG
    /// With `CRUCIBLE_BRAIN=live` a debug session that has no store, as against the mock server, still gets
    /// Crucible's real hosted model, so What to Watch and a described Previously On can be checked end to end.
    private static func installLiveModelIfRequested() {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_BRAIN"] == "live", MidgarProAccess.reachesMidgarServices else { return }
        HostedBrain.install(MidgarHostedBrain.live())
    }
    #endif

    private static var sellsThroughAppStore: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["CRUCIBLE_MOCK"] == nil && environment["CRUCIBLE_UITEST"] == nil && environment["CRUCIBLE_PRO"] == nil
        #else
        return true
        #endif
    }
}
