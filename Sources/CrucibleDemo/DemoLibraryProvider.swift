import CrucibleCore
import Foundation
import os

/// The fictional library of the demo, served from inside the app. The App Store builds hand one of these to `DemoMode`.
///
/// Starting it opens an HTTP server on 127.0.0.1 at an ephemeral port that answers both the plex.tv stand-in and the Plex Media
/// Server routes the app uses, from the catalogue, artwork and clip bundled with this module. Stopping it closes the port; starting
/// again opens a new one. What the viewer watches is kept in a small file in Application Support, so the demo remembers across launches.
package actor DemoLibraryProvider: DemoProviding {
    package static let serverName = "Crucible Demo"
    package static let accountName = "Demo"

    private struct Running {
        let server: DemoHTTPServer
        let library: DemoLibrary
        let endpoint: DemoEndpoint
    }

    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "demo")

    private let assetsOverride: DemoAssets?
    private let stateFileURL: URL?
    private var running: Running?
    private var starting: Task<DemoEndpoint, Error>?

    package init() {
        assetsOverride = nil
        stateFileURL = DemoStateStore.defaultFileURL
    }

    init(assets: DemoAssets?, stateFileURL: URL?) {
        assetsOverride = assets
        self.stateFileURL = stateFileURL
    }

    package func start() async throws -> DemoEndpoint {
        if let running { return running.endpoint }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    package func stop() async {
        if let starting { _ = try? await starting.value }
        guard let current = running else { return }
        running = nil
        await current.server.stop()
        await current.library.flush()
        Self.log.notice("Demo library stopped")
    }

    private func launch() async throws -> DemoEndpoint {
        let assets = try assetsOverride ?? DemoAssets.bundled()
        let library = try await DemoLibrary(catalogURL: assets.catalogue, store: DemoStateStore(fileURL: stateFileURL))
        let plexTV = DemoPlexTV(machineIdentifier: library.machineIdentifier, serverName: Self.serverName)
        let router = DemoRouter(library: library, plexTV: plexTV, assets: assets, serverName: Self.serverName)
        let server = DemoHTTPServer { await router.handle($0) }
        let port = try await server.start()
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw DemoServerError.notReady }
        let endpoint = DemoEndpoint(
            serverURL: url,
            plexTVURL: url,
            token: DemoPlexTV.token,
            machineIdentifier: library.machineIdentifier,
            serverName: Self.serverName,
            accountName: Self.accountName
        )
        running = Running(server: server, library: library, endpoint: endpoint)
        Self.log.notice("Demo library listening on port \(port)")
        return endpoint
    }
}
