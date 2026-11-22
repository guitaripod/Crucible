import Foundation
import Testing
@testable import CrucibleCore

struct SportsScheduleTests {
    private func settings(_ json: String) throws -> SportsSettings {
        try JSONDecoder().decode(SportsSettings.self, from: Data(json.utf8))
    }

    @Test func readsTheScheduleAndTheServersClock() throws {
        let scheduled = try settings(#"{"on": true, "agreed": true, "schedule": [126, 126, 126, 126, 126, 16777215, 16777215], "timeZone": "Europe/Helsinki", "utcOffset": 7200, "weekday": 4, "hour": 13}"#)
        #expect(scheduled.schedules)
        #expect(scheduled.schedule?.ranges(day: 0) == [1..<7])
        #expect(scheduled.schedule?.ranges(day: 6) == [0..<24])
        #expect(scheduled.schedule?.hours == 5 * 6 + 48)
        #expect(scheduled.weekday == 4 && scheduled.hour == 13)

        let anyTime = try settings(#"{"on": true, "agreed": true, "schedule": null, "utcOffset": 0}"#)
        #expect(anyTime.schedules && anyTime.schedule == nil)

        let older = try settings(#"{"on": true, "agreed": true}"#)
        #expect(!older.schedules, "a server from before schedules sends no clock")
    }

    @Test func readsWhenTheScheduleStartsAndStopsResearch() throws {
        let status = try JSONDecoder().decode(SportsStatus.self, from: Data(#"{"phase": "scheduled", "opensAt": 1795000000, "closesAt": null, "byHand": false}"#.utf8))
        #expect(status.isWaitingForHours && !status.isWorking)
        #expect(status.opensAt == 1_795_000_000 && status.closesAt == nil)
        let older = try JSONDecoder().decode(SportsStatus.self, from: Data(#"{"phase": "idle"}"#.utf8))
        #expect(older.opensAt == nil && !older.byHand)
    }

    @Test func choosesHoursDaysAndWholeColumns() {
        var schedule = SportsSchedule.Preset.overnight.schedule
        #expect(schedule.preset == .overnight)
        schedule.set(day: 2, hour: 22, to: true)
        schedule.set(day: 2, hour: 23, to: true)
        #expect(schedule.preset == nil)
        #expect(schedule.ranges(day: 2) == [1..<7, 22..<24])
        schedule.copy(day: 2, to: 0..<5)
        #expect(schedule.ranges(day: 4) == [1..<7, 22..<24])
        #expect(schedule.ranges(day: 5) == [1..<7])
        #expect(!schedule.allDays(hour: 22))
        schedule.set(hour: 22, to: true)
        #expect(schedule.allDays(hour: 22))
        schedule.set(day: 6, to: 0)
        #expect(schedule.ranges(day: 6).isEmpty)
        schedule.set(day: 6, to: SportsSchedule.wholeDay)
        #expect(schedule.ranges(day: 6) == [0..<24])
    }

    @Test func groupsDaysWithTheSameHours() {
        let schedule = SportsSchedule.Preset.nightsAndWeekends.schedule
        let groups = schedule.dayGroups
        #expect(groups.map(\.days) == [0...4, 5...6])
        #expect(SportsSchedule.Preset.workday.schedule.dayGroups.map(\.days) == [0...4], "days with no hours are left out")
        #expect(SportsSchedule(days: [1, 2, 3]).isAlways, "anything but seven days reads as any time")
    }

    @Test func everyPresetIsItsOwnSchedule() {
        let schedules = SportsSchedule.Preset.allCases.map(\.schedule)
        #expect(Set(schedules).count == schedules.count)
        #expect(SportsSchedule.Preset.allCases.allSatisfy { $0.schedule.preset == $0 })
        #expect(SportsSchedule.Preset.anyTime.schedule.isAlways)
    }

    @Test func expectingAScheduleKeepsAnyTimeAsNone() throws {
        let report = SportsReport(owner: true, ready: true, checks: [], settings: SportsSettings(on: true, agreed: true, utcOffset: 0), libraries: [], status: SportsStatus(phase: "idle"), counts: [:], items: [])
        #expect(report.expecting(schedule: .Preset.weekends.schedule).settings.schedule == .Preset.weekends.schedule)
        #expect(report.expecting(schedule: .always).settings.scheduleMasks == nil)
        #expect(report.expecting(schedule: nil).settings.scheduleMasks == nil)
    }

    @Test func namesTheServersZoneOnlyWhenItsClockDiffers() {
        let here = TimeZone.current.secondsFromGMT()
        #expect(SportsCopy.clockNote(SportsSettings(on: true, agreed: true, timeZone: "Somewhere/Here", utcOffset: here)) == nil)
        #expect(SportsCopy.zone(SportsSettings(on: true, agreed: true, utcOffset: 19800)) == "UTC+5:30")
        #expect(SportsCopy.zone(SportsSettings(on: true, agreed: true, utcOffset: -18000)) == "UTC-5")
        #expect(SportsCopy.clockNote(SportsSettings(on: true, agreed: true, timeZone: "Elsewhere/There", utcOffset: here + 3600))?.contains("Elsewhere/There") == true)
    }

    @Test func summarisesTheWeek() {
        #expect(SportsCopy.summary(nil) == SportsCopy.anyTime)
        #expect(SportsCopy.summary(.always) == SportsCopy.anyTime)
        let summary = SportsCopy.summary(SportsSchedule.Preset.nightsAndWeekends.schedule)
        #expect(summary.contains(" · "))
        #expect(summary.contains(SportsCopy.allDay))
        #expect(SportsCopy.scheduleValue(SportsSchedule.Preset.weekends.schedule) == SportsCopy.preset(.weekends))
        var custom = SportsSchedule.Preset.weekends.schedule
        custom.set(day: 0, hour: 3, to: true)
        #expect(SportsCopy.scheduleValue(custom) == SportsCopy.custom)
    }
}

struct SportsScheduleLiveTests {
    private static let environment = ProcessInfo.processInfo.environment

    /// A running Crucible Server takes a schedule, reports it back with its clock and when research next starts or stops,
    /// and takes Any time back as no schedule.
    @Test(.enabled(if: environment["CRUCIBLE_SERVER_SCHEDULE_CODE"] != nil))
    func aRunningServerKeepsTheScheduleTheOwnerSets() async throws {
        let environment = Self.environment
        let invite = try #require(CompanionInvite(code: environment["CRUCIBLE_SERVER_SCHEDULE_CODE"] ?? "", hosts: [environment["CRUCIBLE_SERVER_SCHEDULE_HOST"] ?? ""]))
        let server = try await CompanionPairing.pair(invite, deviceName: "Schedule Tests", platform: "test", machineIdentifier: nil)
        let client = CompanionClient(server: server, plexToken: environment["CRUCIBLE_SERVER_SCHEDULE_PLEX_TOKEN"] ?? "")
        let before = try await client.sports()
        #expect(before.owner)
        #expect(before.settings.schedules)
        #expect(before.settings.weekday.map { (0..<7).contains($0) } == true)

        let overnight = SportsSchedule.Preset.overnight.schedule
        try await client.scheduleSports(overnight)
        let scheduled = try await client.sports()
        #expect(scheduled.settings.schedule == overnight)
        #expect((scheduled.status.opensAt == nil) != (scheduled.status.closesAt == nil), "exactly one of when research starts or stops")
        let next = try #require(scheduled.status.opensAt ?? scheduled.status.closesAt)
        #expect(next > Int(Date().timeIntervalSince1970) && next <= Int(Date().timeIntervalSince1970) + 25 * 3600)

        var custom = SportsSchedule.Preset.weekends.schedule
        custom.set(day: 2, hour: 13, to: true)
        try await client.scheduleSports(custom)
        #expect(try await client.sports().settings.schedule == custom)

        await #expect(throws: CompanionError.self) {
            try await client.scheduleSports(SportsSchedule(days: Array(repeating: 0, count: 7)))
        }

        try await client.scheduleSports(nil)
        let anyTime = try await client.sports()
        #expect(anyTime.settings.schedule == nil)
        #expect(anyTime.status.opensAt == nil && anyTime.status.closesAt == nil)
        try await client.scheduleSports(.always)
        #expect(try await client.sports().settings.schedule == nil)
        print("SCHEDULE", scheduled.settings.timeZone ?? "-", scheduled.settings.utcOffset ?? 0, scheduled.status.opensAt ?? 0, scheduled.status.closesAt ?? 0)
    }
}
