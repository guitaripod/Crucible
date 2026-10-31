import Foundation
import Testing
@testable import CrucibleCore

struct SettingsDiagnosticsTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crucible-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func files(in directory: URL, previous: String?, current: String?) throws -> LogFiles {
        let files = LogFiles(
            current: directory.appendingPathComponent("crucible.log"),
            previous: directory.appendingPathComponent("crucible.previous.log")
        )
        if let previous { try previous.write(to: files.previous, atomically: true, encoding: .utf8) }
        if let current { try current.write(to: files.current, atomically: true, encoding: .utf8) }
        return files
    }

    @Test func deviceDescriptionJoinsSystemAndModel() {
        #expect(DiagnosticsReport.deviceDescription(systemName: "iOS", systemVersion: "26.1", model: "iPhone") == "iOS 26.1 · iPhone")
    }

    @Test func headerListsVersionDeviceAndExportTime() {
        let header = DiagnosticsReport.header(
            deviceDescription: "tvOS 26.5 · Apple TV",
            info: ["CFBundleShortVersionString": "2.1.0", "CFBundleVersion": "9"],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(header == "Crucible 2.1.0 (9)\ntvOS 26.5 · Apple TV\nExported 1970-01-01T00:00:00Z")
    }

    @Test func headerUsesQuestionMarksWhenTheBundleHasNoVersion() {
        let header = DiagnosticsReport.header(deviceDescription: "d", info: nil, now: Date(timeIntervalSince1970: 0))
        #expect(header.hasPrefix("Crucible ? (?)\n"))
    }

    @Test func reportHoldsPreviousThenCurrentLog() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: "old line\n", current: "new line\n")
        let url = try #require(DiagnosticsReport.assemble(header: "HEADER", files: logs, directory: folder, now: Date(timeIntervalSince1970: 42)))
        #expect(url.lastPathComponent == "Crucible-Logs-42.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "HEADER\n\n=== Previous log ===\nold line\n\n=== Current log ===\nnew line\n")
    }

    @Test func reportSkipsAnEmptySection() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: "only\n")
        let url = try #require(DiagnosticsReport.assemble(header: "H", files: logs, directory: folder))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Previous log"))
        #expect(text.contains("=== Current log ===\nonly\n"))
    }

    @Test func noLogsMeansNoReport() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: nil)
        #expect(DiagnosticsReport.assemble(header: "H", files: logs, directory: folder) == nil)
    }

    @Test func reportFailsQuietlyWhenTheDestinationIsMissing() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: "x\n")
        let missing = folder.appendingPathComponent("nope", isDirectory: true)
        #expect(DiagnosticsReport.assemble(header: "H", files: logs, directory: missing) == nil)
    }

    @Test func tailKeepsTheNewestLinesAcrossBothLogs() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: "a\nb\nc\n", current: "d\ne\n")
        let tail = LogTail.read(files: logs, maxLines: 3)
        #expect(tail.lines == ["c", "d", "e"])
        #expect(tail.totalLineCount == 5)
        #expect(tail.byteCount == 10)
        #expect(!tail.isEmpty)
    }

    @Test func tailCountsErrorsAndFaultsAcrossTheWholeLog() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = """
        2026-01-01T00:00:00.000Z [42] [info  ] [ui          ] fine
        2026-01-01T00:00:01.000Z [42] [error ] [networking  ] boom
        2026-01-01T00:00:02.000Z [42] [fault ] [lifecycle   ] worse
        2026-01-01T00:00:03.000Z [42] [notice] [ui          ] ok
        """
        let logs = try files(in: folder, previous: nil, current: current)
        let tail = LogTail.read(files: logs, maxLines: 1)
        #expect(tail.lines.count == 1)
        #expect(tail.totalLineCount == 4)
        #expect(tail.errorCount == 2)
    }

    @Test func tailOfAMissingLogIsEmpty() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: nil)
        let tail = LogTail.read(files: logs, maxLines: 200)
        #expect(tail == LogTail(lines: [], totalLineCount: 0, errorCount: 0, byteCount: 0))
        #expect(tail.isEmpty)
    }

    @Test func tailDropsBlankLinesAndHandlesWindowsEndings() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: "one\r\n\r\ntwo\n\n")
        #expect(LogTail.read(files: logs, maxLines: 10).lines == ["one", "two"])
    }

    @Test func aZeroLineLimitKeepsTheCountsButNoLines() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let logs = try files(in: folder, previous: nil, current: "one\ntwo\n")
        let tail = LogTail.read(files: logs, maxLines: 0)
        #expect(tail.lines.isEmpty)
        #expect(tail.totalLineCount == 2)
    }

    @Test func imageCacheSizeSumsRegularFilesRecursively() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: folder.appendingPathComponent("one.jpg"))
        try Data(count: 500).write(to: nested.appendingPathComponent("two.jpg"))
        #expect(ImageCacheMeter.measure(root: folder) == 1500)
    }

    @Test func imageCacheSizeOfAMissingFolderIsZero() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(ImageCacheMeter.measure(root: missing) == 0)
    }

    @Test func emptyCacheReadsEmpty() {
        #expect(ImageCacheMeter.formatted(0) == "Empty")
        #expect(ImageCacheMeter.formatted(2_000_000).hasSuffix("MB"))
    }
}

struct SettingsAppInfoTests {
    @Test func versionAndBuildFallBackWhenTheBundleIsSilent() {
        #expect(AppInfo.versionText(from: nil) == "1.0")
        #expect(AppInfo.buildText(from: [:]) == "1")
    }

    @Test func versionAndBuildComeFromTheInfoDictionary() {
        let info: [String: Any] = ["CFBundleShortVersionString": "2.0.1", "CFBundleVersion": "12"]
        #expect(AppInfo.versionText(from: info) == "2.0.1")
        #expect(AppInfo.buildText(from: info) == "12")
    }

    @Test func licenceAndSourceMatchTheIPhoneAboutScreen() {
        #expect(AppInfo.licenseName == "GPL-3.0")
        #expect(AppInfo.sourceURL?.absoluteString == "https://github.com/guitaripod/Crucible")
        #expect(AppInfo.licenseSummary.contains("GNU General Public License v3.0"))
    }

    @Test func grdbIsAcknowledged() throws {
        let grdb = try #require(AppInfo.acknowledgements.first { $0.name == "GRDB.swift" })
        #expect(grdb.license == "MIT")
        #expect(grdb.url.host == "github.com")
    }
}
