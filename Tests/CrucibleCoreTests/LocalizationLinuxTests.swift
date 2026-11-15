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
}
#endif
