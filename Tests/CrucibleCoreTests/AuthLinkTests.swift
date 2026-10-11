import Foundation
import Testing
@testable import CrucibleCore

struct AuthLinkTests {
    private let expires = Date(timeIntervalSince1970: 2_000_000)

    private func code(_ value: String, id: Int, lifetime: TimeInterval = 900) -> PlexPinCode {
        PlexPinCode(id: id, code: value, expiresAt: expires.addingTimeInterval(lifetime))
    }

    @Test func theReducerWaitsForBothCodesBeforeAnnouncing() throws {
        var reducer = PlexLinkReducer(clientIdentifier: "client")
        #expect(reducer.apply(.requesting, from: .short) == nil)
        #expect(reducer.apply(.waiting(code("ABCD", id: 1)), from: .short) == nil)

        let result = reducer.apply(.waiting(code("longstrongcode", id: 2, lifetime: 600)), from: .strong)
        let announced = try #require(result)
        let url = try #require(PlexAuthURL.url(clientIdentifier: "client", code: "longstrongcode"))
        #expect(announced == .waiting(PlexLinkCodes(shortCode: "ABCD", authURL: url, expiresAt: expires.addingTimeInterval(600))))
    }

    @Test func theReducerAnnouncesTheCodesOnlyOnce() {
        var reducer = PlexLinkReducer(clientIdentifier: "client")
        _ = reducer.apply(.waiting(code("ABCD", id: 1)), from: .short)
        _ = reducer.apply(.waiting(code("strong", id: 2)), from: .strong)
        #expect(reducer.apply(.waiting(code("ABCD", id: 1)), from: .short) == nil)
    }

    @Test func eitherPinClaimingExpiringOrFailingEndsTheSession() {
        var reducer = PlexLinkReducer(clientIdentifier: "client")
        #expect(reducer.apply(.claimed(token: "t"), from: .strong) == .claimed(token: "t"))
        #expect(reducer.apply(.expired, from: .short) == .expired)
        #expect(reducer.apply(.failed("offline"), from: .strong) == .failed("offline"))
    }

    @Test func aSessionShowsBothCodesAndFinishesWhenTheQRPinIsApproved() async throws {
        let strongPending = AuthFixtures.pin(id: 2, code: "strongcode", token: nil)
        let strongApproved = AuthFixtures.pin(id: 2, code: "strongcode", token: "approved")
        let script = AuthScriptedPins(
            create: { strong in .success(strong ? AuthFixtures.pin(id: 2, code: "strongcode") : AuthFixtures.pin(id: 1, code: "ABCD")) },
            check: { id, attempt in
                if id == 2 && attempt >= 2 { return .success(strongApproved) }
                return .success(id == 2 ? strongPending : AuthFixtures.pin(id: 1, code: "ABCD", token: nil))
            }
        )
        let clock = AuthStubClock()
        let session = PlexLinkSession(transport: script.transport, clock: clock.clock, clientIdentifier: { "client" })
        let states = await authCollect(session.states())

        #expect(states.first == .requesting)
        #expect(states.last == .claimed(token: "approved"))
        let url = try #require(PlexAuthURL.url(clientIdentifier: "client", code: "strongcode"))
        #expect(states.contains(.waiting(PlexLinkCodes(shortCode: "ABCD", authURL: url, expiresAt: clock.start.addingTimeInterval(900)))))
        #expect(Set(script.created.value) == [true, false])
    }

    @Test func aSessionFinishesWhenTheShortCodeIsTypedAtPlexTv() async {
        let script = AuthScriptedPins(
            create: { strong in .success(strong ? AuthFixtures.pin(id: 2, code: "strongcode") : AuthFixtures.pin(id: 1, code: "ABCD")) },
            check: { id, attempt in
                if id == 1 && attempt >= 2 { return .success(AuthFixtures.pin(id: 1, code: "ABCD", token: "typed")) }
                return .success(AuthFixtures.pin(id: id, code: "x", token: nil))
            }
        )
        let states = await authCollect(PlexLinkSession(transport: script.transport, clock: AuthStubClock().clock, clientIdentifier: { "client" }).states())

        #expect(states.last == .claimed(token: "typed"))
    }

    @Test func aSessionExpiresWhenTheCodesRunOut() async {
        let script = AuthScriptedPins(
            create: { strong in .success(AuthFixtures.pin(id: strong ? 2 : 1, code: strong ? "strongcode" : "ABCD", expiresIn: 2)) },
            check: { id, _ in .success(AuthFixtures.pin(id: id, code: "x", token: nil)) }
        )
        let states = await authCollect(PlexLinkSession(transport: script.transport, clock: AuthStubClock().clock, clientIdentifier: { "client" }).states())

        #expect(states.last == .expired)
    }

    @Test func aSessionFailsWhenEitherPinCannotBeRequested() async {
        let script = AuthScriptedPins(
            create: { strong in strong ? .failure(APIError.serverUnavailable) : .success(AuthFixtures.pin()) },
            check: { _, _ in .success(AuthFixtures.pin(token: nil)) }
        )
        let states = await authCollect(PlexLinkSession(transport: script.transport, clock: AuthStubClock().clock, clientIdentifier: { "client" }).states())

        #expect(states.last == .failed(APIError.serverUnavailable.localizedDescription))
    }
}
