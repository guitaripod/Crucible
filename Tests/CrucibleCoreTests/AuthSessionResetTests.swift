import Foundation
import Testing
@testable import CrucibleCore

@MainActor
@Suite(.serialized)
struct AuthSessionResetTests {
    private final class Calls {
        var stats = 0
        var images = 0
        var topShelf = 0
        var downloads = 0
    }

    private func collaborators(_ calls: Calls) -> AccountSessionCollaborators {
        AccountSessionCollaborators(
            resetStats: { calls.stats += 1 },
            clearImageCache: { calls.images += 1 },
            topShelfDidChange: { calls.topShelf += 1 },
            resetDownloads: { calls.downloads += 1 }
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "auth-session-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func seedServerBoundState() {
        let libraries = AuthFixtures.decode([PlexDirectory].self, #"[{"key":"2","type":"movie","title":"Movies"},{"key":"3","type":"show","title":"Shows"}]"#)
        LibraryVisibility.record(directories: libraries)
        LibraryVisibility.setIncluded(2, false)
        Preferences.recentSearches = ["alien", "heat"]
    }

    private func cleanUp() {
        LibraryVisibility.forgetServerLibraries()
        Preferences.recentSearches = []
    }

    @Test func connectingToADifferentServerForgetsWhatBelongedToTheOldOne() {
        defer { cleanUp() }
        let defaults = isolatedDefaults()
        let calls = Calls()
        seedServerBoundState()

        #expect(!AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(calls), defaults: defaults))
        #expect(calls.stats == 0)
        #expect(!LibraryVisibility.libraries.isEmpty)

        #expect(AccountSessionReset.reconcileServer(machineIdentifier: "server-b", collaborators(calls), defaults: defaults))
        #expect(calls.stats == 1)
        #expect(calls.images == 1)
        #expect(calls.downloads == 0)
        #expect(LibraryVisibility.libraries.isEmpty)
        #expect(!LibraryVisibility.hasOverrides)
        #expect(Preferences.recentSearches.isEmpty)
    }

    @Test func theSameServerKeepsEverything() {
        defer { cleanUp() }
        let defaults = isolatedDefaults()
        let calls = Calls()
        AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(calls), defaults: defaults)
        seedServerBoundState()

        #expect(!AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(calls), defaults: defaults))
        #expect(calls.stats == 0)
        #expect(calls.images == 0)
        #expect(!LibraryVisibility.libraries.isEmpty)
        #expect(Preferences.recentSearches == ["alien", "heat"])
    }

    @Test func aFirstLaunchOnlyAdoptsTheServer() {
        defer { cleanUp() }
        let defaults = isolatedDefaults()
        let calls = Calls()
        seedServerBoundState()

        #expect(!AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(calls), defaults: defaults))
        #expect(calls.stats == 0)
        #expect(Preferences.recentSearches == ["alien", "heat"])
        #expect(defaults.string(forKey: "plex_session_machine_id") == "server-a")
    }

    @Test func changingServerKeepsTheRememberedAddressOfTheNewOne() {
        defer { cleanUp() }
        let defaults = isolatedDefaults()
        let address = ServerAddress.parse("10.0.0.9")!
        AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(Calls()), defaults: defaults)
        RememberedServerAddress.remember(address, in: defaults)

        AccountSessionReset.reconcileServer(machineIdentifier: "server-b", collaborators(Calls()), defaults: defaults)
        #expect(defaults.string(forKey: "last_server_ip") == "10.0.0.9")
    }

    @Test func signingOutForgetsTheAccountAndEverythingBoundToIt() {
        defer { cleanUp() }
        let defaults = isolatedDefaults()
        let calls = Calls()
        seedServerBoundState()
        ServerBootstrap.saveToken("account-token")
        ServerBootstrap.saveServer(uri: URL(string: "http://10.0.0.2:32400")!, name: "Home", machineIdentifier: "server-a")
        RememberedServerAddress.remember(ServerAddress.parse("10.0.0.2")!, in: defaults)
        AccountSessionReset.reconcileServer(machineIdentifier: "server-a", collaborators(calls), defaults: defaults)

        AccountSessionReset.signOut(collaborators(calls), defaults: defaults)

        #expect(calls.downloads == 1)
        #expect(calls.stats == 1)
        #expect(calls.images == 1)
        #expect(ServerBootstrap.connection() == nil)
        #expect(defaults.string(forKey: "last_server_ip") == nil)
        #expect(defaults.string(forKey: "plex_session_machine_id") == nil)
        #expect(LibraryVisibility.libraries.isEmpty)
        #expect(Preferences.recentSearches.isEmpty)
    }

    @Test func theRouteStatusForgetsTheOldServer() {
        let status = YouConnectionStatus()
        status.refresh(baseURL: { URL(string: "http://10.0.0.2:32400")! }, identityCheck: { true })
        status.reset()
        #expect(status.state == .connecting)
        #expect(status.task == nil)
    }

    @Test func sharedLibraryChoicesAreKeyedByServerSoTheyMustNotSurviveASwitch() {
        defer { cleanUp() }
        seedServerBoundState()
        ServerBootstrap.saveServer(uri: URL(string: "http://10.0.0.3:32400")!, name: "Other", machineIdentifier: "server-b")
        #expect(LibraryVisibility.hasOverrides)
        #expect(!LibraryVisibility.isIncluded(2))
        ServerBootstrap.clear()
    }
}
