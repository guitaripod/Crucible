#if !canImport(Darwin)
@testable import CrucibleCore
import Foundation
import Testing

struct LocalizationLinuxTests {
    @Test func aPercentBetweenValuesIsDoubledInTheKeyAsXcodeWritesIt() {
        let score = 92
        let value: String.LocalizationValue = "\(score)% match"
        #expect(value.key == "%lld%% match")
        let phrase = "in 2026"
        let detail: String.LocalizationValue = "watched \(phrase) · estimate, \(score)% counted"
        #expect(detail.key == "watched %@ · estimate, %lld%% counted")
    }

    @Test func aPlainLiteralKeepsItsPercent() {
        let value: String.LocalizationValue = "100% sure"
        #expect(value.key == "100% sure")
    }

    @Test func theFallbackStillReadsWithOnePercent() {
        let score = 92
        #expect(String(localized: "\(score)% match") == "92% match")
    }

    @Test func aSecondCatalogAddsItsStringsInTheLanguageTheFirstChose() throws {
        let catalog = LocalizationCatalog()
        let shared = #"{"sourceLanguage":"en","strings":{"Play":{"localizations":{"fi":{"stringUnit":{"state":"translated","value":"Toista"}},"de":{"stringUnit":{"state":"translated","value":"Wiedergabe"}}}}},"version":"1.0"}"#
        let own = #"{"sourceLanguage":"en","strings":{"Watch Later":{"localizations":{"fi":{"stringUnit":{"state":"translated","value":"Katso myöhemmin"}},"de":{"stringUnit":{"state":"translated","value":"Später ansehen"}}}},"Shorts":{"localizations":{"de":{"stringUnit":{"state":"translated","value":"Kurzvideos"}}}}},"version":"1.0"}"#
        try catalog.load(xcstrings: Data(shared.utf8), preferredLanguages: ["fi-FI"])
        try catalog.add(xcstrings: Data(own.utf8))
        #expect(catalog.currentLanguage == "fi")
        #expect(catalog.string(key: "Play", fallback: "Play", arguments: []) == "Toista")
        #expect(catalog.string(key: "Watch Later", fallback: "Watch Later", arguments: []) == "Katso myöhemmin")
        #expect(catalog.string(key: "Shorts", fallback: "Shorts", arguments: []) == "Shorts")
    }
}
#endif
