import Testing
@testable import CrucibleStats

struct StatsFormatTests {
    @Test(arguments: [
        (0, "0"), (7, "7"), (999, "999"),
        (1_000, "1K"), (1_234, "1.2K"), (1_250, "1.3K"), (9_999, "10K"),
        (10_000, "10K"), (15_500, "16K"),
        (1_000_000, "1M"), (1_250_000, "1.3M"), (12_000_000, "12M"),
        (-1_500, "-1.5K"),
    ])
    func abbreviatesCounts(value: Int, expected: String) {
        #expect(StatsFormat.abbreviatedCount(value) == expected)
    }

    @Test func weekdayLabelsStartOnSundayAndClamp() {
        #expect((1...7).map(StatsFormat.weekdayShort) == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
        #expect(StatsFormat.weekdayShort(0) == "Sun")
        #expect(StatsFormat.weekdayShort(9) == "Sat")
    }
}
