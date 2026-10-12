import CrucibleCore
import Foundation

/// The fictional library of the demo, served from inside the app. The App Store builds hand one of these to `DemoMode`.
package final class DemoLibraryProvider: DemoProviding {
    package init() {}

    package func start() async throws -> DemoEndpoint {
        throw DemoError.unavailable
    }

    package func stop() async {}
}
