import Foundation
import Testing
@testable import CrucibleCore

struct AuthLaunchTests {
    private let saved = AuthFixtures.connection()

    @Test func anUnreachableServerWithAnAcceptedTokenIsUnreachable() async {
        let result = await AppLaunchSession.run(
            connection: saved,
            progress: { _ in },
            validate: { _ in .needsSetup },
            tokenRejected: { _ in false }
        )
        guard case .failure(let failure) = result, case .unreachable = failure else {
            Issue.record("expected unreachable, got \(result)")
            return
        }
        #expect(failure.message == "None of the server's known addresses answered. Check that it's online and reachable from this network.")
    }

    @Test func anUnreachableServerWithARevokedTokenIsAnExpiredSignIn() async {
        let result = await AppLaunchSession.run(
            connection: saved,
            progress: { _ in },
            validate: { _ in .needsSetup },
            tokenRejected: { token in token == "tok" }
        )
        guard case .failure(let failure) = result, case .signInExpired = failure else {
            Issue.record("expected signInExpired, got \(result)")
            return
        }
        #expect(failure.message == "Authentication expired. Please sign in again.")
    }

    @Test func aFetchRejectedWithUnauthorizedIsAnExpiredSignIn() {
        guard case .signInExpired = LaunchFailure.fetchFailure(APIError.unauthorized) else {
            Issue.record("expected signInExpired")
            return
        }
        guard case .fetch = LaunchFailure.fetchFailure(APIError.serverUnavailable) else {
            Issue.record("expected fetch")
            return
        }
    }

    @Test func onlyAnExplicit401MeansThePlexTokenIsRejected() async {
        #expect(await PlexTokenCheck.isRejected(token: "t") { _ in 401 })
        #expect(!(await PlexTokenCheck.isRejected(token: "t") { _ in 200 }))
        #expect(!(await PlexTokenCheck.isRejected(token: "t") { _ in 500 }))
        #expect(!(await PlexTokenCheck.isRejected(token: "t") { _ in throw URLError(.notConnectedToInternet) }))
    }

    @Test func theTokenCheckAsksPlexTvForTheAccountWithTheToken() async {
        let seen = AuthLocked<URLRequest?>(nil)
        _ = await PlexTokenCheck.isRejected(token: "secret") { request in
            seen.update { $0 = request }
            return 200
        }
        let request = seen.value
        #expect(request?.url?.path == "/api/v2/user")
        #expect(request?.value(forHTTPHeaderField: "X-Plex-Token") == "secret")
    }

    @Test func savedRoutesAreUniqueAndKeepThePinnedOneFirst() {
        let pinned = URL(string: "http://10.0.0.2:32400")!
        let other = URL(string: "https://nas.example.com:32400")!
        let ordered = ServerBootstrap.orderedRoutes(primary: pinned, others: [other, pinned, other, URL(string: "http://100.64.0.2:32400")!])
        #expect(ordered == [pinned, other, URL(string: "http://100.64.0.2:32400")!])
    }

    @Test func everyRouteKindHasOneSymbol() {
        #expect(ConnectionKind.local.symbolName == "house")
        #expect(ConnectionKind.tailscale.symbolName == "network")
        #expect(ConnectionKind.remote.symbolName == "globe")
        #expect(ConnectionKind.relay.symbolName == "arrow.triangle.swap")
        #expect(ServerRoute.Kind.relay == ConnectionKind.relay)
    }
}
