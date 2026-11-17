import Foundation
import Testing
@testable import CrucibleCore

struct WelcomeLedgerTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "welcome-\(UUID().uuidString)")!
    }

    @Test func aNewInstallOwesTheWelcomeUntilItIsShown() {
        let ledger = WelcomeLedger(defaults: defaults())
        #expect(!ledger.isWelcomeOwed)
        ledger.settleAtLaunch()
        #expect(ledger.isWelcomeOwed)
        ledger.welcomeWasShown()
        #expect(!ledger.isWelcomeOwed)
    }

    @Test func anUpdateFromAVersionWithoutTheWelcomeOwesNothing() {
        let store = defaults()
        store.set("http://10.0.0.2:32400", forKey: "plex_server_uri")
        let ledger = WelcomeLedger(defaults: store)
        ledger.settleAtLaunch()
        #expect(!ledger.isWelcomeOwed)
    }

    @Test func theFirstLaunchDecidesOnceAndASavedServerLaterChangesNothing() {
        let store = defaults()
        let ledger = WelcomeLedger(defaults: store)
        ledger.settleAtLaunch()
        store.set("http://10.0.0.2:32400", forKey: "plex_server_uri")
        ledger.settleAtLaunch()
        #expect(ledger.isWelcomeOwed)
    }

    @Test func clearedDataOwesTheWelcomeAgain() {
        let suite = "welcome-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let ledger = WelcomeLedger(defaults: store)
        ledger.settleAtLaunch()
        ledger.welcomeWasShown()
        store.removePersistentDomain(forName: suite)
        ledger.settleAtLaunch()
        #expect(ledger.isWelcomeOwed)
    }

    @Test func notNowPutsTheTraktInvitationAway() {
        let ledger = WelcomeLedger(defaults: defaults())
        #expect(!ledger.isTraktInviteDismissed)
        ledger.dismissTraktInvite()
        #expect(ledger.isTraktInviteDismissed)
    }

    #if DEBUG
    @Test func aStagedFreshInstallOwesTheWelcomeOnlyWhenAsked() {
        let ledger = WelcomeLedger(defaults: defaults())
        ledger.dismissTraktInvite()
        ledger.stageFreshInstall(owesWelcome: false)
        #expect(!ledger.isWelcomeOwed)
        #expect(!ledger.isTraktInviteDismissed)
        ledger.stageFreshInstall(owesWelcome: true)
        #expect(ledger.isWelcomeOwed)
    }
    #endif
}

struct WelcomePlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func standing(_ status: ProStatus, storeBacked: Bool = true, week: ProWeek.Phase = .notStarted) -> WelcomePlan.Standing {
        WelcomePlan.standing(status: status, isStoreBacked: storeBacked, proWeek: week)
    }

    @Test func aBuildNotSoldInTheStoreHasEverythingOpen() {
        #expect(standing(.pro(.included), storeBacked: false) == .included)
        #expect(standing(.free, storeBacked: false) == .included)
    }

    @Test func aStoreThatHasNotAnsweredIsStillChecking() {
        #expect(standing(.unknown) == .checking)
    }

    @Test func aFreeViewerHearsAboutTheWeekOnlyWhileItIsAhead() {
        #expect(standing(.free, week: .notStarted) == .freeWeekAhead)
        #expect(standing(.free, week: .active(endsAt: now)) == .proWeek(endsAt: now))
        #expect(standing(.free, week: .ended(at: now)) == .free)
    }

    @Test func aBuyerATrialAndAFamilyAreToldApart() {
        let lifetime = ProEntitlement(kind: .lifetime, productIdentifier: "lifetime")
        let family = ProEntitlement(kind: .lifetime, productIdentifier: "lifetime", isFamilyShared: true)
        let trial = ProEntitlement(kind: .subscription, productIdentifier: "yearly", expiresAt: now, isTrial: true)
        #expect(standing(.pro(lifetime)) == .pro(familyShared: false))
        #expect(standing(.pro(family)) == .pro(familyShared: true))
        #expect(standing(.pro(trial)) == .trial(endsAt: now))
    }

    @Test func traktIsOfferedOnlyWhereItCanBeConnected() {
        #expect(WelcomePlan.traktStep(.disconnected) == .invite)
        #expect(WelcomePlan.traktStep(.needsReconnect) == .reconnect)
        #expect(WelcomePlan.traktStep(.unavailable) == nil)
        #expect(WelcomePlan.traktStep(.restricted) == nil)
        let profile = TraktProfile(username: "marcus", name: nil, isVIP: false, avatarURL: nil)
        #expect(WelcomePlan.traktStep(.connected(profile)) == .connected(username: "marcus"))
        #expect(WelcomePlan.traktStep(.connected(nil)) == .connected(username: nil))
    }

    @Test func onlyABuyerIsCelebratedAndOnlyAFreeViewerPastTheWeekIsOfferedPro() {
        #expect(WelcomePlan(standing: .pro(familyShared: false), trakt: nil).celebrates)
        #expect(!WelcomePlan(standing: .trial(endsAt: nil), trakt: nil).celebrates)
        #expect(WelcomePlan(standing: .free, trakt: nil).offersPro)
        #expect(!WelcomePlan(standing: .freeWeekAhead, trakt: nil).offersPro)
        #expect(!WelcomePlan(standing: .pro(familyShared: false), trakt: nil).offersPro)
    }

    @Test func theFreeAppIsListedUntilProIsOpen() {
        let free = WelcomePlan(standing: .freeWeekAhead, trakt: .invite)
        #expect(!free.listsProFeatures)
        #expect(free.freeHighlights(includingDownloads: true).count == 4)
        #expect(free.freeHighlights(includingDownloads: false).count == 3)
        #expect(!free.freeHighlights(includingDownloads: false).contains { $0.symbol == "arrow.down.circle" })
        let open = WelcomePlan(standing: .proWeek(endsAt: now), trakt: .invite)
        #expect(open.listsProFeatures)
        #expect(open.freeHighlights(includingDownloads: true).isEmpty)
    }

    @Test func everyStandingHasItsOwnWords() {
        let standings: [WelcomePlan.Standing] = [
            .checking, .freeWeekAhead, .free, .proWeek(endsAt: now), .trial(endsAt: now), .trial(endsAt: nil),
            .pro(familyShared: false), .pro(familyShared: true), .included,
        ]
        let messages = standings.map { WelcomePlan(standing: $0, trakt: nil).standingMessage }
        #expect(Set(messages).count == standings.count)
        #expect(standings.allSatisfy { !WelcomePlan(standing: $0, trakt: nil).standingTitle.isEmpty })
        #expect(WelcomeCopy.message(of: .included, isLinux: true) != WelcomeCopy.message(of: .included, isLinux: false))
    }

    @Test func theTraktStepAsksOnlyUntilItIsConnected() {
        #expect(WelcomeCopy.action(of: .invite) == TraktCopy.connect)
        #expect(WelcomeCopy.action(of: .reconnect) == TraktCopy.reconnect)
        #expect(WelcomeCopy.action(of: .connected(username: "marcus")) == nil)
        #expect(WelcomeCopy.message(of: .connected(username: "marcus")).contains("marcus"))
    }
}

struct TraktInviteTests {
    @Test func itInvitesWhileTraktIsNotConnected() {
        let invite = TraktInvite.due(status: .disconnected, dismissed: false, titleName: "Arrival")
        #expect(invite?.kind == .connect)
        #expect(invite?.action == TraktCopy.connect)
        #expect(invite?.message.contains("Arrival") == true)
    }

    @Test func itAsksAgainWhenTraktSignedCrucibleOut() {
        let invite = TraktInvite.due(status: .needsReconnect, dismissed: false, titleName: "Arrival")
        #expect(invite?.kind == .reconnect)
        #expect(invite?.action == TraktCopy.reconnect)
    }

    @Test func itStaysAwayWhereItHasNothingToOfferOrWasPutAway() {
        let profile = TraktProfile(username: "marcus", name: nil, isVIP: false, avatarURL: nil)
        #expect(TraktInvite.due(status: .connected(profile), dismissed: false, titleName: "Arrival") == nil)
        #expect(TraktInvite.due(status: .unavailable, dismissed: false, titleName: "Arrival") == nil)
        #expect(TraktInvite.due(status: .restricted, dismissed: false, titleName: "Arrival") == nil)
        #expect(TraktInvite.due(status: .disconnected, dismissed: true, titleName: "Arrival") == nil)
        #expect(TraktInvite.due(status: .needsReconnect, dismissed: true, titleName: "Arrival") == nil)
    }

    @Test func aTitleWithoutANameStillReadsWell() {
        let invite = TraktInvite.due(status: .disconnected, dismissed: false, titleName: "")
        #expect(invite?.message.isEmpty == false)
        #expect(invite?.message.contains("  ") == false)
    }
}

extension SavedSessionSuites {
    /// Points Trakt at a stand-in address, as the demo does, so this build without Trakt's client ID can load an account; it runs
    /// beside the demo's suites, which set the same address, one at a time.
    @MainActor
    @Suite(.serialized)
    struct TraktInviteLoadTests {
        private func account() -> TraktAccount {
            let store = TraktTokenStore(keychain: .memory(), owner: { "invite" })
            let client = TraktClient(transport: TraktScript().transport, tokens: store, sleep: { _ in }, clientID: { "client" })
            return TraktAccount(tokens: store, defaults: UserDefaults(suiteName: "invite-\(UUID().uuidString)")!, client: client)
        }

        @Test func nothingIsOfferedUntilTheAccountHasLoaded() async {
            TraktConfig.setOverride(URL(string: "http://127.0.0.1:9"))
            defer { TraktConfig.setOverride(nil) }
            let account = account()
            let ledger = WelcomeLedger(defaults: UserDefaults(suiteName: "invite-ledger-\(UUID().uuidString)")!)
            #expect(account.status == .disconnected)
            #expect(TraktInvite.current(titleName: "Arrival", account: account, ledger: ledger) == nil)
            #expect(WelcomePlan.current(account: account).trakt == nil)
            var heard = 0
            _ = account.observe { heard += 1 }
            await account.load()
            #expect(account.hasLoaded)
            #expect(heard == 1)
            #expect(TraktInvite.current(titleName: "Arrival", account: account, ledger: ledger)?.kind == .connect)
            #expect(WelcomePlan.current(account: account).trakt == .invite)
        }
    }
}
