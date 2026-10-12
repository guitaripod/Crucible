import Foundation
import Testing
@testable import CrucibleCore

@MainActor
@Suite(.serialized)
struct DemoModeTests {
    private final class FakeLibrary: DemoProviding, @unchecked Sendable {
        var starts = 0
        var stops = 0
        var failing = false
        var port = 41000

        func start() async throws -> DemoEndpoint {
            starts += 1
            if failing { throw DemoError.unavailable }
            port += 1
            return DemoEndpoint(
                serverURL: URL(string: "http://127.0.0.1:\(port)")!,
                plexTVURL: URL(string: "http://127.0.0.1:\(port)")!,
                token: "demo-token",
                machineIdentifier: "demo-machine",
                serverName: "Crucible Demo",
                accountName: "Demo"
            )
        }

        func stop() async { stops += 1 }
    }

    private struct Fixture {
        let mode: DemoMode
        let library: FakeLibrary
        let access: ProAccess
        let defaults: UserDefaults
    }

    private func fixture(installed: Bool = true) -> Fixture {
        let defaults = UserDefaults(suiteName: "demo-mode-\(UUID().uuidString)")!
        let access = ProAccess(provider: ScriptedProAccess(status: .free, delay: .milliseconds(1)))
        access.apply(.free)
        let mode = DemoMode(defaults: defaults, access: access)
        let library = FakeLibrary()
        if installed { mode.install(library) }
        return Fixture(mode: mode, library: library, access: access, defaults: defaults)
    }

    private func collaborators() -> AccountSessionCollaborators {
        AccountSessionCollaborators(resetStats: {}, clearImageCache: {})
    }

    private var savedServerURI: String? { UserDefaults.standard.string(forKey: "plex_server_uri") }

    private func cleanUp() {
        ServerBootstrap.clear()
        PlexTVHost.setOverride(nil)
    }

    @Test func theDemoIsOnlyOfferedWhenALibraryIsInstalled() {
        #expect(!fixture(installed: false).mode.isAvailable)
        #expect(fixture().mode.isAvailable)
    }

    @Test func enteringStartsTheLibrarySignsInToItAndUnlocksEverything() async throws {
        defer { cleanUp() }
        let f = fixture()
        try await f.mode.enter()
        #expect(f.mode.isActive)
        #expect(f.library.starts == 1)
        #expect(savedServerURI == "http://127.0.0.1:41001")
        #expect(UserDefaults.standard.string(forKey: "plex_server_name") == "Crucible Demo")
        #expect(f.defaults.string(forKey: PlexAccountName.defaultsKey) == "Demo")
        #expect(PlexTVHost.account.absoluteString == "http://127.0.0.1:41001")
        #expect(f.access.demoUnlocked)
        #expect(f.access.hasFullAccess)
        #expect(!f.access.isPro)
    }

    @Test func aLibraryThatCannotStartChangesNothing() async {
        defer { cleanUp() }
        let f = fixture()
        f.library.failing = true
        await #expect(throws: DemoError.unavailable) { try await f.mode.enter() }
        #expect(!f.mode.isActive)
        #expect(savedServerURI == nil)
        #expect(!f.access.demoUnlocked)
    }

    @Test func enteringWithNoLibraryThrows() async {
        let f = fixture(installed: false)
        await #expect(throws: DemoError.unavailable) { try await f.mode.enter() }
    }

    @Test func leavingStopsTheLibraryAndForgetsTheSession() async throws {
        defer { cleanUp() }
        let f = fixture()
        try await f.mode.enter()
        await f.mode.exit(collaborators())
        #expect(!f.mode.isActive)
        #expect(f.library.stops == 1)
        #expect(savedServerURI == nil)
        #expect(PlexTVHost.account.absoluteString == "https://plex.tv")
        #expect(!f.access.demoUnlocked)
        #expect(f.mode.endpoint == nil)
    }

    @Test func resumingRestartsTheLibraryOnANewPortAndRepointsTheSession() async throws {
        defer { cleanUp() }
        let f = fixture()
        try await f.mode.enter()
        let resumed = fixture()
        resumed.defaults.set(true, forKey: DemoMode.activeKey)
        resumed.library.port = 50000
        #expect(await resumed.mode.resume())
        #expect(savedServerURI == "http://127.0.0.1:50001")
        #expect(resumed.access.demoUnlocked)
    }

    @Test func resumingWhenNothingWasRunningDoesNothing() async {
        let f = fixture()
        #expect(!(await f.mode.resume()))
        #expect(f.library.starts == 0)
    }

    @Test func resumingWithALibraryThatCannotStartLeavesTheDemo() async {
        defer { cleanUp() }
        let f = fixture()
        f.defaults.set(true, forKey: DemoMode.activeKey)
        f.library.failing = true
        #expect(!(await f.mode.resume()))
        #expect(!f.mode.isActive)
        #expect(!f.access.demoUnlocked)
    }

    @Test func observersHearEnteringAndLeaving() async throws {
        defer { cleanUp() }
        let f = fixture()
        var states: [Bool] = []
        f.mode.observe { states.append($0) }
        try await f.mode.enter()
        await f.mode.exit(collaborators())
        #expect(states == [true, false])
    }

    @Test func theDemoUnlocksFeaturesButNotThePurchase() async throws {
        defer { cleanUp() }
        let access = ProAccess(provider: ScriptedProAccess(status: .free, delay: .milliseconds(1)))
        access.apply(.free)
        #expect(!access.hasFullAccess)
        var shown = false
        access.paywallPresenter = { _, _ in shown = true }
        access.setDemoUnlocked(true)
        var result: Bool?
        access.requestUnlock(.fullStatistics) { result = $0 }
        #expect(result == true)
        #expect(!shown)
        #expect(!access.isPro)
    }
}
