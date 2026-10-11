import Foundation
import Testing
@testable import CrucibleCore

struct FormattersTests {
    @Test func durationRendersHoursMinutesAndFloor() {
        #expect(Formatters.duration(nil) == "")
        #expect(Formatters.duration(-1) == "")
        #expect(Formatters.duration(.infinity) == "")
        #expect(Formatters.duration(.nan) == "")
        #expect(Formatters.duration(30) == "< 1m")
        #expect(Formatters.duration(90) == "1m")
        #expect(Formatters.duration(3600) == "1h 0m")
        #expect(Formatters.duration(3720) == "1h 2m")
    }

    @Test func timestampPadsSecondsAndShowsHoursOnlyWhenNeeded() {
        #expect(Formatters.timestamp(0) == "0:00")
        #expect(Formatters.timestamp(65) == "1:05")
        #expect(Formatters.timestamp(3725) == "1:02:05")
    }

    @Test func fileSizeSwitchesBetweenMegabytesAndGigabytes() {
        #expect(Formatters.fileSize(524_288_000) == "500 MB")
        #expect(Formatters.fileSize(1_073_741_824) == "1.0 GB")
        #expect(Formatters.fileSize(1_610_612_736) == "1.5 GB")
    }

    @Test func resolutionBucketsByHeight() {
        #expect(Formatters.resolution(3840, 2160) == "4K")
        #expect(Formatters.resolution(1920, 1080) == "1080p")
        #expect(Formatters.resolution(1280, 720) == "720p")
        #expect(Formatters.resolution(720, 480) == "480p")
        #expect(Formatters.resolution(640, 360) == "360p")
        #expect(Formatters.resolution(1920, nil) == nil)
    }

    @Test func episodeCodeNeedsBothParts() {
        #expect(Formatters.episodeCode(1, 2) == "S01E02")
        #expect(Formatters.episodeCode(12, 104) == "S12E104")
        #expect(Formatters.episodeCode(nil, 2) == nil)
        #expect(Formatters.episodeCode(1, nil) == nil)
    }

    @Test func ratingKeepsOneDecimal() {
        #expect(Formatters.rating(7.84) == "7.8")
        #expect(Formatters.rating(10) == "10.0")
        #expect(Formatters.rating(nil) == nil)
    }

    @Test func channelDescriptionNamesCommonLayouts() {
        #expect(Formatters.channelDescription(8) == "7.1")
        #expect(Formatters.channelDescription(6) == "5.1")
        #expect(Formatters.channelDescription(2) == "Stereo")
        #expect(Formatters.channelDescription(1) == "Mono")
        #expect(Formatters.channelDescription(4) == "4ch")
        #expect(Formatters.channelDescription(nil) == "Unknown")
    }

    @Test func plexDateRejectsMalformedInput() {
        #expect(Formatters.plexDate(nil) == nil)
        #expect(Formatters.plexDate("not a date") == nil)
        #expect(Formatters.plexDate("2021-03-05") != nil)
    }

    @Test func relativeDateParsesIsoWithAndWithoutFractionalSeconds() {
        #expect(Formatters.relativeDate(nil) == nil)
        #expect(Formatters.relativeDate("garbage") == nil)
        #expect(Formatters.relativeDate("2020-01-01T00:00:00Z") != nil)
        #expect(Formatters.relativeDate("2020-01-01T00:00:00.250Z") != nil)
    }

    @Test func unixDatesHandleNil() {
        #expect(Formatters.unixRelativeDate(nil) == nil)
        #expect(Formatters.unixDate(nil) == nil)
        #expect(Formatters.unixRelativeDate(0) != nil)
        #expect(Formatters.unixDate(0) != nil)
    }
}
