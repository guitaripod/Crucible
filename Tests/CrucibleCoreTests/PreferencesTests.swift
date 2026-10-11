import Foundation
import Testing
@testable import CrucibleCore

@Suite(.serialized)
struct PreferencesTests {
    @Test func downloadQualityDefaultsToHighUntilChosen() {
        let key = "downloadQuality"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(Preferences.downloadQuality == .high)
        Preferences.downloadQuality = .original
        #expect(Preferences.downloadQuality == .original)
    }

    @Test func downloadQualityBitrateAndEstimates() {
        #expect(DownloadQuality.original.maxVideoBitrate == nil)
        #expect(DownloadQuality.medium.maxVideoBitrate == 8000)
        #expect(DownloadQuality.original.estimatedBytes(durationMs: 10_000) == 0)
        #expect(DownloadQuality.medium.estimatedBytes(durationMs: 10_000) == 10_240_000)
    }

    @Test func downloadQualityRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(DownloadQuality.low)
        #expect(try JSONDecoder().decode(DownloadQuality.self, from: data) == .low)
        #expect(String(data: data, encoding: .utf8) == "3000")
    }

    @Test func downloadQualityLabels() {
        #expect(DownloadQuality.allCases.map(\.shortLabel) == ["Original", "1080p", "720p", "480p", "360p"])
        #expect(DownloadQuality.saver.title == "Data Saver")
    }
}
