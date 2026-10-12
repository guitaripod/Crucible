import Foundation

/// Debug builds only: a demo that points at a mock Plex server already running (the repo's `marketing/mock/server.py`), named by
/// `CRUCIBLE_DEMO_URL`. It lets the demo screens be built and tested before, and without, the in-app library.
#if DEBUG
package final class DemoMockProvider: DemoProviding {
    package static let environmentVariable = "CRUCIBLE_DEMO_URL"

    private let base: URL

    package init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment[Self.environmentVariable], let url = URL(string: raw), url.host?.isEmpty == false else { return nil }
        base = url
    }

    package func start() async throws -> DemoEndpoint {
        DemoEndpoint(
            serverURL: base,
            plexTVURL: base,
            token: "mock-token",
            machineIdentifier: "9c1f0e2a7b3d4e5f8a6b1c2d3e4f5a6b",
            serverName: "Crucible Demo",
            accountName: "Demo"
        )
    }

    package func stop() async {}
}
#endif
