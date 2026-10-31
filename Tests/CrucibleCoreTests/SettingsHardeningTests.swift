import Foundation
import Testing
@testable import CrucibleCore

struct UniquedTests {
    @Test func keepsTheFirstOfEachIdentifierInOrder() {
        let rows = [("a", 1), ("b", 2), ("a", 3), ("c", 4), ("b", 5)]
        #expect(rows.uniqued(by: \.0).map(\.1) == [1, 2, 4])
    }

    @Test func emptyAndAlreadyUniqueListsAreUnchanged() {
        #expect([Int]().uniqued(by: \.self).isEmpty)
        #expect([3, 1, 2].uniqued(by: \.self) == [3, 1, 2])
    }

    @Test func uniquedRowsAreSafeForDictionaryUniqueKeys() {
        let identifiers = ["server.route.x", "server.route.y", "server.route.x"]
        let dictionary = Dictionary(uniqueKeysWithValues: identifiers.uniqued(by: \.self).map { ($0, true) })
        #expect(dictionary.count == 2)
    }
}

struct ReloadThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func neverLoadedIsNotFresh() {
        #expect(!ReloadThrottle(interval: 60).isFresh(now: start))
    }

    @Test func freshUntilTheIntervalHasPassed() {
        var throttle = ReloadThrottle(interval: 60)
        throttle.markLoaded(at: start)
        #expect(throttle.isFresh(now: start.addingTimeInterval(59.9)))
        #expect(!throttle.isFresh(now: start.addingTimeInterval(60)))
    }

    @Test func invalidateForcesTheNextLoad() {
        var throttle = ReloadThrottle(interval: 60)
        throttle.markLoaded(at: start)
        throttle.invalidate()
        #expect(!throttle.isFresh(now: start))
    }

    @Test func aNewLoadRestartsTheWindow() {
        var throttle = ReloadThrottle(interval: 60)
        throttle.markLoaded(at: start)
        throttle.markLoaded(at: start.addingTimeInterval(100))
        #expect(throttle.isFresh(now: start.addingTimeInterval(150)))
    }
}

struct LogTailErrorLineTests {
    @Test func errorAndFaultLinesAreErrors() {
        #expect(LogTail.isError("2026-01-01T00:00:00.000Z [42] [error ] [networking  ] boom"))
        #expect(LogTail.isError("2026-01-01T00:00:00.000Z [42] [fault ] [lifecycle   ] worse"))
        #expect(!LogTail.isError("2026-01-01T00:00:00.000Z [42] [info  ] [ui          ] error handling is fine"))
        #expect(!LogTail.isError("2026-01-01T00:00:00.000Z [42] [notice] [ui          ] ok"))
    }
}

@MainActor
struct ServerRoutesAreUniqueTests {
    private nonisolated static let local = URL(string: "http://192.168.1.10:32400")!
    private nonisolated static let remote = URL(string: "https://203-0-113-7.abc.plex.direct:32400")!

    @Test func aCandidateListedTwiceBecomesOneRoute() {
        let connection = PlexConnection(
            serverURI: Self.local,
            serverName: "Marcus-PC",
            machineIdentifier: "m",
            authToken: "t",
            clientIdentifier: "c",
            candidateURIs: [Self.local, Self.remote, Self.remote, Self.local]
        )
        let model = ServerConnectionModel(environment: .init(
            connection: { connection },
            probe: { _, _ in nil },
            serverResource: { _ in nil }
        ))
        #expect(model.routes == [Self.local, Self.remote])
        #expect(Set(model.routeRows.map(\.url)).count == model.routeRows.count)
    }

    @Test func theActiveRouteIsNotRepeatedWhenItIsAlsoACandidate() {
        let connection = PlexConnection(
            serverURI: Self.remote,
            serverName: "Marcus-PC",
            machineIdentifier: "m",
            authToken: "t",
            clientIdentifier: "c",
            candidateURIs: [Self.local, Self.local]
        )
        let model = ServerConnectionModel(environment: .init(
            connection: { connection },
            probe: { _, _ in nil },
            serverResource: { _ in nil }
        ))
        #expect(model.routes == [Self.remote, Self.local])
    }
}
