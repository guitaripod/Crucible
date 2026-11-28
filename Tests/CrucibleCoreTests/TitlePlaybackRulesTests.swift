import Foundation
import Testing
@testable import CrucibleCore

struct TitlePlaybackRulesTests {
    @Test func aShowsOwnCountdownWinsOverSettingsAndOldDataFollowsSettings() throws {
        var rules = TitlePlaybackRules()
        #expect(rules.countdown(settings: 10) == 10)
        rules.upNextCountdown = 0
        #expect(rules.hasRules)
        #expect(rules.countdown(settings: 10) == 0)
        rules.upNextCountdown = 7
        #expect(rules.countdown(settings: 15) == 15)
        let old = try JSONDecoder().decode(TitlePlaybackRules.self, from: Data(#"{"skips":{},"matchContent":false,"autoplay":true}"#.utf8))
        #expect(old.upNextCountdown == nil)
        #expect(old.countdown(settings: 5) == 5)
    }

    @Test func aShowOnAppleDevicesKeepsItsOwnCountdownPerServer() throws {
        let defaults = try #require(UserDefaults(suiteName: "show-countdown-\(UUID().uuidString)"))
        #expect(ShowUpNextCountdown.seconds(forShow: "42", server: "a", defaults: defaults) == nil)
        #expect(ShowUpNextCountdown.choices(forShow: "42", server: "a", defaults: defaults).first?.isSelected == true)
        ShowUpNextCountdown.set(0, forShow: "42", server: "a", defaults: defaults)
        #expect(ShowUpNextCountdown.effective(forShow: "42", server: "a", defaults: defaults) == 0)
        #expect(ShowUpNextCountdown.seconds(forShow: "42", server: "b", defaults: defaults) == nil)
        #expect(ShowUpNextCountdown.choices(forShow: "42", server: "a", defaults: defaults).first { $0.isSelected }?.seconds == 0)
        #expect(ShowUpNextCountdown.menuTitle(forShow: "42", server: "a", defaults: defaults) == "Up Next: Instant")
        ShowUpNextCountdown.set(7, forShow: "42", server: "a", defaults: defaults)
        #expect(ShowUpNextCountdown.seconds(forShow: "42", server: "a", defaults: defaults) == nil)
        ShowUpNextCountdown.set(nil, forShow: "42", server: "a", defaults: defaults)
        #expect(ShowUpNextCountdown.seconds(forShow: "42", server: "a", defaults: defaults) == nil)
    }

    @Test func everyMarkerKindHasASetting() {
        #expect(SkipKind(.intro) == .intro)
        #expect(SkipKind(.recap) == .recap)
        #expect(SkipKind(.credits) == .credits)
        #expect(SkipKind(.ending) == .credits)
        #expect(SkipKind(.preview) == .preview)
        #expect(SkipKind(.commercial) == .commercial)
    }

    @Test func creditsHaveNoAfterTheFirstEpisode() {
        #expect(!SkipKind.credits.modes.contains(.afterFirstEpisode))
        #expect(SkipKind.intro.modes == SkipMode.allCases)
        #expect(SkipMode.afterFirstEpisode.creditsMode == .button)
        #expect(SkipMode.automatic.creditsMode == .automatic)
        #expect(SkipMode.off.creditsMode == .off)
    }

    private func marker(_ kind: SkipMarker.Kind) -> SkipMarker {
        SkipMarker(kind: kind, startSecs: 10, endSecs: 60)
    }

    @Test func afterTheFirstEpisodeOffersInTheOneStartedAndSkipsInTheOnesAfter() {
        #expect(SkipDecision.decide(.afterFirstEpisode, for: marker(.intro), titlesBefore: 0) == .offer)
        #expect(SkipDecision.decide(.afterFirstEpisode, for: marker(.intro), titlesBefore: 1) == .skip)
        #expect(SkipDecision.decide(.afterFirstEpisode, for: marker(.recap), titlesBefore: 3) == .skip)
    }

    @Test func closingCreditsAreOfferedNeverSkippedOnTheirOwn() {
        #expect(SkipDecision.decide(.automatic, for: marker(.credits), titlesBefore: 0) == .offer)
        #expect(SkipDecision.decide(.afterFirstEpisode, for: marker(.credits), titlesBefore: 2) == .offer)
        #expect(SkipDecision.decide(.off, for: marker(.credits), titlesBefore: 0) == .ignore)
        #expect(SkipDecision.decide(.automatic, for: marker(.ending), titlesBefore: 0) == .skip)
    }

    @Test func theOtherModesMeanWhatTheySay() {
        for kind in [SkipMarker.Kind.intro, .recap, .preview, .commercial] {
            #expect(SkipDecision.decide(.automatic, for: marker(kind), titlesBefore: 0) == .skip)
            #expect(SkipDecision.decide(.button, for: marker(kind), titlesBefore: 4) == .offer)
            #expect(SkipDecision.decide(.off, for: marker(kind), titlesBefore: 4) == .ignore)
        }
    }

    @Test func aTitlesRulesWinOverSettingsAndFollowThemOtherwise() {
        var rules = TitlePlaybackRules(name: "The Show", isShow: true)
        #expect(!rules.hasRules)
        #expect(rules.mode(for: .intro, settings: .button) == .button)
        #expect(rules.autoplays(settings: true))
        rules[.intro] = .automatic
        rules.autoplay = false
        #expect(rules.hasRules)
        #expect(rules.mode(for: .intro, settings: .button) == .automatic)
        #expect(rules.mode(for: .credits, settings: .off) == .off)
        #expect(!rules.autoplays(settings: true))
        rules[.intro] = nil
        rules.autoplay = nil
        #expect(!rules.hasRules)
        rules.matchContent = true
        #expect(rules.hasRules)
    }

    @Test func rulesSurviveBeingKept() throws {
        var rules = TitlePlaybackRules(name: "A Film", isShow: false)
        rules[.credits] = .off
        rules[.recap] = .afterFirstEpisode
        rules.matchContent = true
        let kept = try JSONDecoder().decode(TitlePlaybackRules.self, from: JSONEncoder().encode(rules))
        #expect(kept == rules)
        #expect(kept[.recap] == .afterFirstEpisode)
    }

    @Test func theSharedSkipSettingsMapOntoModes() {
        #expect(SkipMode(Preferences.SkipIntroMode.automatic) == .automatic)
        #expect(SkipMode(Preferences.SkipIntroMode.off) == .off)
        #expect(SkipMode(Preferences.SkipOutroMode.button) == .button)
    }
}
