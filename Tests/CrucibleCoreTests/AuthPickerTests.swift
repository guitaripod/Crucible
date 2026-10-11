import Foundation
import Testing
@testable import CrucibleCore

struct AuthPickerTests {
    private func picker(_ servers: [ServerChoice]) -> ServerPickerState {
        ServerPickerState(choices: servers)
    }

    private let home = AuthFixtures.choice(name: "Home", id: "a", uris: ["http://192.168.1.5:32400", "http://203.0.113.7:32400"])
    private let office = AuthFixtures.choice(name: "Office", id: "b", uris: ["http://10.0.0.8:32400"])
    private let offline = AuthFixtures.choice(name: "Attic", id: "c", online: false, uris: ["http://10.0.0.9:32400"])

    @Test func theFirstOnlineServerStartsSelected() {
        #expect(picker([offline, home, office]).selectedID == "a")
        #expect(picker([offline]).selectedID == nil)
    }

    @Test func offlineServersCannotBeSelected() {
        let state = picker([home, offline])
        #expect(state.isSelectable("a"))
        #expect(!state.isSelectable("c"))
        #expect(!state.isSelectable("nope"))
    }

    @Test func choosingReportsWhetherTheSelectionMoved() {
        var state = picker([home, office])
        let unchanged = state.choose("a")
        let moved = state.choose("b")
        #expect(!unchanged)
        #expect(moved)
        #expect(state.selectedChoice?.name == "Office")
    }

    @Test func probeTargetsCoverEveryRouteOfEveryOnlineServer() {
        let state = picker([home, offline, office])
        let targets = state.probeTargets
        #expect(targets.map(\.serverID) == ["a", "a", "b"])
        #expect(targets.map(\.routeIndex) == [0, 1, 0])
        #expect(state.unprobeableRoutes.isEmpty)
    }

    @Test func routesWithoutAnAddressCanNeverBeProbed() {
        let broken = AuthFixtures.choice(name: "Broken", id: "d", uris: ["http://10.0.0.1:32400", ""])
        let state = picker([broken])
        #expect(state.probeTargets.count == 1)
        #expect(state.unprobeableRoutes.map(\.routeIndex) == [1])
        #expect(state.unprobeableRoutes.map(\.serverID) == ["d"])
    }

    @Test func recordingStoresLatencyAndIgnoresUnknownServers() {
        var state = picker([home])
        let known = state.record(server: "a", route: 0, milliseconds: 14)
        let unknown = state.record(server: "zzz", route: 0, milliseconds: 14)
        #expect(known)
        #expect(!unknown)
        #expect(state.choices[0].routes[0].milliseconds == 14)
        state.record(server: "a", route: 1, milliseconds: nil)
        #expect(state.choices[0].routes[1].state == .unreachable)
    }

    @Test func finishingProbesSelectsTheFastestServerUnlessThePersonChose() {
        var automatic = picker([home, office])
        automatic.record(server: "a", route: 0, milliseconds: 40)
        automatic.record(server: "a", route: 1, milliseconds: nil)
        automatic.record(server: "b", route: 0, milliseconds: 6)
        let moved = automatic.finishProbing()
        #expect(moved)
        #expect(automatic.selectedID == "b")
        let movedAgain = automatic.finishProbing()
        #expect(!movedAgain)

        var chosen = picker([home, office])
        chosen.record(server: "a", route: 0, milliseconds: 40)
        chosen.record(server: "b", route: 0, milliseconds: 6)
        chosen.choose("b")
        chosen.choose("a")
        let movedAfterChoice = chosen.finishProbing()
        #expect(!movedAfterChoice)
        #expect(chosen.selectedID == "a")
    }

    @Test func finishingProbesWithNothingReachableChangesNothing() {
        var state = picker([home])
        state.record(server: "a", route: 0, milliseconds: nil)
        state.record(server: "a", route: 1, milliseconds: nil)
        let moved = state.finishProbing()
        #expect(!moved)
        #expect(state.selectedID == "a")
    }

    @Test func theConnectButtonFollowsTheSelectedServersProbes() {
        var state = picker([home])
        #expect(state.connectAction(isConnecting: false) == .testing(serverName: "Home"))
        state.record(server: "a", route: 0, milliseconds: nil)
        #expect(state.connectAction(isConnecting: false) == .testing(serverName: "Home"))
        state.record(server: "a", route: 1, milliseconds: nil)
        #expect(state.connectAction(isConnecting: false) == .noRoute(serverName: "Home"))
        state.record(server: "a", route: 1, milliseconds: 30)
        #expect(state.connectAction(isConnecting: false) == .ready(serverName: "Home"))
        #expect(state.connectAction(isConnecting: true) == .connecting)
        #expect(picker([offline]).connectAction(isConnecting: false) == .chooseServer)
    }

    @Test func connectActionsCarryTheirCopyAndFlags() {
        #expect(ServerPickerState.ConnectAction.chooseServer.title == "Choose a Server")
        #expect(ServerPickerState.ConnectAction.testing(serverName: "Home").title == "Testing connections…")
        #expect(ServerPickerState.ConnectAction.noRoute(serverName: "Home").title == "No route to Home")
        #expect(ServerPickerState.ConnectAction.ready(serverName: "Home").title == "Connect to Home")
        #expect(ServerPickerState.ConnectAction.connecting.title == "Connecting…")
        #expect(ServerPickerState.ConnectAction.connecting.showsActivity)
        #expect(ServerPickerState.ConnectAction.testing(serverName: "Home").showsActivity)
        #expect(!ServerPickerState.ConnectAction.ready(serverName: "Home").showsActivity)
        #expect(ServerPickerState.ConnectAction.ready(serverName: "Home").isEnabled)
        #expect(!ServerPickerState.ConnectAction.noRoute(serverName: "Home").isEnabled)
    }

    @Test func exactlyOneReachableServerContinuesAutomaticallyOnceProbesSettle() {
        var state = picker([home, office, offline])
        #expect(state.autoContinue == nil)

        state.record(server: "a", route: 0, milliseconds: nil)
        state.record(server: "a", route: 1, milliseconds: nil)
        #expect(state.autoContinue == nil)

        state.record(server: "b", route: 0, milliseconds: 9)
        let target = state.autoContinue
        #expect(target?.choice.id == "b")
        #expect(target?.route.uri == "http://10.0.0.8:32400")
    }

    @Test func twoReachableServersAreARealChoiceAndNoneIsADeadEnd() {
        var both = picker([home, office])
        both.record(server: "a", route: 0, milliseconds: 5)
        both.record(server: "a", route: 1, milliseconds: nil)
        both.record(server: "b", route: 0, milliseconds: 9)
        #expect(both.autoContinue == nil)

        var none = picker([office])
        none.record(server: "b", route: 0, milliseconds: nil)
        #expect(none.autoContinue == nil)
    }

    @Test func aServerStillBeingProbedHoldsBackAutoContinue() {
        var state = picker([home, office])
        state.record(server: "b", route: 0, milliseconds: 9)
        state.record(server: "a", route: 0, milliseconds: nil)
        #expect(state.autoContinue == nil)
    }

    @Test func reachabilitySummarisesEachServer() {
        var state = picker([home, offline])
        #expect(state.choices[0].reachability == .probing)
        #expect(state.choices[1].reachability == .offline)
        state.record(server: "a", route: 0, milliseconds: nil)
        state.record(server: "a", route: 1, milliseconds: nil)
        #expect(state.choices[0].reachability == .unreachable)
        state.record(server: "a", route: 1, milliseconds: 12)
        #expect(state.choices[0].reachability == .reachable)
    }
}
