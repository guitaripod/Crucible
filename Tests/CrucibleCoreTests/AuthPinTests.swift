import Foundation
import Testing
@testable import CrucibleCore

struct AuthPinTests {
    private let pending = AuthScriptedPins.Reply.success(AuthFixtures.pin(token: nil))
    private let claimed = AuthScriptedPins.Reply.success(AuthFixtures.pin(token: "secret"))

    @Test func authURLKeepsTheFormTheIPhoneAlwaysUsed() {
        let url = PlexAuthURL.url(clientIdentifier: "6F0B8E4C-0C6A-4D5E-9A67-52F1C1B0A9D2", code: "abc123xyz")
        #expect(url?.absoluteString == "https://app.plex.tv/auth#?clientID=6F0B8E4C-0C6A-4D5E-9A67-52F1C1B0A9D2&code=abc123xyz&context%5Bdevice%5D%5Bproduct%5D=Crucible")
    }

    @Test func authURLEscapesAnythingThatCouldBreakTheQuery() {
        let url = PlexAuthURL.url(clientIdentifier: "a&b", code: "x y#z")
        #expect(url?.absoluteString.contains("clientID=a%26b&code=x%20y%23z&") == true)
    }

    @Test func strongPinsAskForTheLongCodeAndShortPinsDoNot() {
        let strong = PlexEndpoint.pinFormBody(strong: true)
        let short = PlexEndpoint.pinFormBody(strong: false)
        #expect(strong.hasPrefix("strong=true&X-Plex-Product=Crucible&X-Plex-Client-Identifier="))
        #expect(short.hasPrefix("X-Plex-Product=Crucible&X-Plex-Client-Identifier="))
        #expect(!short.contains("strong"))
    }

    @Test func mockOverrideAppliesOnlyToDebugBuildsWithAWellFormedURL() {
        let environment = [PlexTVHost.environmentVariable: " http://127.0.0.1:32530 "]
        #expect(PlexTVHost.parseOverride(in: environment, allowed: true)?.absoluteString == "http://127.0.0.1:32530")
        #expect(PlexTVHost.parseOverride(in: environment, allowed: false) == nil)
        #expect(PlexTVHost.parseOverride(in: [:], allowed: true) == nil)
        #expect(PlexTVHost.parseOverride(in: [PlexTVHost.environmentVariable: "ftp://host"], allowed: true) == nil)
        #expect(PlexTVHost.parseOverride(in: [PlexTVHost.environmentVariable: "not a url"], allowed: true) == nil)
        #expect(PlexTVHost.parseOverride(in: [PlexTVHost.environmentVariable: ""], allowed: true) == nil)
    }

    @Test func pinResponsesCarryTheirLifetime() {
        #expect(AuthFixtures.pin(expiresIn: 600).expiresIn == 600)
        #expect(AuthFixtures.pin(expiresIn: nil).expiresIn == nil)
    }

    @Test func aPinIsClaimedOnTheThirdPollAfterRequestingAndWaiting() async {
        let clock = AuthStubClock()
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin(id: 7, code: "QWER")), checks: [pending, pending, claimed])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: clock.clock).states())

        let expected = PlexPinCode(id: 7, code: "QWER", expiresAt: clock.start.addingTimeInterval(900))
        #expect(states == [.requesting, .waiting(expected), .claimed(token: "secret")])
        #expect(script.created.value == [false])
        #expect(script.checked.value == [7, 7, 7])
        #expect(clock.sleeps.value == Array(repeating: .seconds(1), count: 3))
    }

    @Test func strongPinsAreRequestedStrong() async {
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [claimed])
        _ = await authCollect(PlexPinAuth(strong: true, transport: script.transport, clock: AuthStubClock().clock).states())
        #expect(script.created.value == [true])
    }

    @Test func expiryComesFromTheResponseAndEndsPolling() async {
        let clock = AuthStubClock()
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin(expiresIn: 3)), checks: [pending])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: clock.clock).states())

        #expect(states.last == .expired)
        #expect(states.count == 3)
        #expect(script.checked.value.count == 3)
    }

    @Test func aMissingLifetimeFallsBackToFifteenMinutes() async {
        let clock = AuthStubClock()
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin(expiresIn: nil)), checks: [claimed])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: clock.clock).states())

        guard case .waiting(let code) = states[1] else {
            Issue.record("expected a waiting state, got \(states)")
            return
        }
        #expect(code.expiresAt == clock.start.addingTimeInterval(900))
    }

    @Test func thePhoneTimingPollsEveryTwoSecondsForAtMostFiveMinutes() async {
        let clock = AuthStubClock()
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin(expiresIn: 900)), checks: [pending])
        let states = await authCollect(PlexPinAuth(strong: true, timing: .phoneWeb, transport: script.transport, clock: clock.clock).states())

        #expect(states.last == .expired)
        #expect(script.checked.value.count == 150)
        #expect(clock.sleeps.value.allSatisfy { $0 == .seconds(2) })
    }

    @Test func plexTvForgettingThePinMeansItExpired() async {
        let missing = AuthScriptedPins.Reply.failure(APIError.httpError(statusCode: 404, message: "Not Found"))
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [pending, missing])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states.last == .expired)
        #expect(script.checked.value.count == 2)
    }

    @Test func pollFailuresAreRiddenOutUntilTheyPileUp() async {
        let offline = AuthScriptedPins.Reply.failure(URLError(.notConnectedToInternet))
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [offline])
        var timing = PlexPinTiming.standard
        timing.maxConsecutivePollFailures = 3
        let states = await authCollect(PlexPinAuth(strong: false, timing: timing, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states.last == .failed(URLError(.notConnectedToInternet).localizedDescription))
        #expect(script.checked.value.count == 3)
    }

    @Test func aSuccessfulPollResetsTheFailureCount() async {
        let offline = AuthScriptedPins.Reply.failure(URLError(.timedOut))
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [offline, offline, pending, offline, offline, claimed])
        var timing = PlexPinTiming.standard
        timing.maxConsecutivePollFailures = 3
        let states = await authCollect(PlexPinAuth(strong: false, timing: timing, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states.last == .claimed(token: "secret"))
    }

    @Test func thePhoneTimingNeverGivesUpOnFailedPolls() async {
        let offline = AuthScriptedPins.Reply.failure(URLError(.timedOut))
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [offline])
        let states = await authCollect(PlexPinAuth(strong: true, timing: .phoneWeb, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states.last == .expired)
    }

    @Test func aFailedPinRequestEndsRightAway() async {
        let script = AuthScriptedPins(create: .failure(APIError.serverUnavailable), checks: [pending])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states == [.requesting, .failed(APIError.serverUnavailable.localizedDescription)])
        #expect(script.checked.value.isEmpty)
    }

    @Test func anEmptyTokenDoesNotCountAsClaimed() async {
        let blank = AuthScriptedPins.Reply.success(AuthFixtures.pin(token: ""))
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin(expiresIn: 2)), checks: [blank])
        let states = await authCollect(PlexPinAuth(strong: false, transport: script.transport, clock: AuthStubClock().clock).states())

        #expect(states.last == .expired)
    }

    @Test func cancellingTheConsumerStopsPollingWithoutATerminalState() async throws {
        let script = AuthScriptedPins(create: .success(AuthFixtures.pin()), checks: [pending])
        let slowClock = PlexPinClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let stream = PlexPinAuth(strong: false, transport: script.transport, clock: slowClock).states()
        let consumer = Task { await authCollect(stream) }

        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        let states = await consumer.value

        #expect(states.first == .requesting)
        #expect(!states.contains { $0.isTerminal })
        #expect(script.checked.value.isEmpty)
    }
}
