import Foundation
import Testing
@testable import CrucibleCore
@testable import CrucibleStats

@MainActor
@Suite(.serialized)
struct AuthStatsSessionTests {
    private func client() -> APIClient {
        APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t")
    }

    @Test func aNewSessionNeverInheritsASyncStartedForTheOldOne() {
        let manager = StatsManager.shared
        manager.handleSignOut()
        defer { manager.handleSignOut() }

        manager.configure(api: client())
        manager.kickBackgroundSync()
        #expect(manager.hasRunningSync)

        manager.configure(api: client())
        #expect(!manager.hasRunningSync)
    }

    @Test func theSameClientKeepsItsRunningSync() {
        let manager = StatsManager.shared
        manager.handleSignOut()
        defer { manager.handleSignOut() }
        let shared = client()

        manager.configure(api: shared)
        manager.kickBackgroundSync()
        manager.configure(api: shared)
        #expect(manager.hasRunningSync)
    }

    @Test func signingOutCancelsEverythingAndDropsTheStore() {
        let manager = StatsManager.shared
        manager.handleSignOut()
        manager.configure(api: client())
        manager.kickBackgroundSync()

        manager.handleSignOut()
        #expect(!manager.hasRunningSync)
        #expect(manager.store == nil)
    }
}
