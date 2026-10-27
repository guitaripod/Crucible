import Foundation

/// The two rotating log files `LogFileWriter` keeps.
package struct LogFiles: Sendable {
    package let current: URL
    package let previous: URL

    package static var live: LogFiles {
        let current = URL(fileURLWithPath: LogFileWriter.shared.currentPath)
        return LogFiles(current: current, previous: current.deletingLastPathComponent().appendingPathComponent("crucible.previous.log"))
    }
}

/// Builds the temporary text file behind "Share Diagnostic Logs".
package enum DiagnosticsReport {
    /// "iOS 26.1 · iPhone", from the UIKit device values the platform layer passes in.
    package static func deviceDescription(systemName: String, systemVersion: String, model: String) -> String {
        "\(systemName) \(systemVersion) · \(model)"
    }

    package static func export(deviceDescription: String) async -> URL? {
        LogFileWriter.shared.writeSync("Diagnostics export requested")
        let header = header(deviceDescription: deviceDescription)
        let files = LogFiles.live
        return await Task.detached(priority: .userInitiated) {
            assemble(header: header, files: files, directory: FileManager.default.temporaryDirectory)
        }.value
    }

    static func header(deviceDescription: String, info: [String: Any]? = Bundle.main.infoDictionary, now: Date = Date()) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return [
            "Crucible \(version) (\(build))",
            deviceDescription,
            "Exported \(ISO8601DateFormatter().string(from: now))",
        ].joined(separator: "\n")
    }

    static func assemble(header: String, files: LogFiles, directory: URL, now: Date = Date()) -> URL? {
        let previous = (try? String(contentsOf: files.previous, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: files.current, encoding: .utf8)) ?? ""
        guard !previous.isEmpty || !current.isEmpty else { return nil }

        var report = header + "\n"
        if !previous.isEmpty { report += "\n=== Previous log ===\n" + previous }
        if !current.isEmpty { report += "\n=== Current log ===\n" + current }

        let stamp = Int(now.timeIntervalSince1970)
        let url = directory.appendingPathComponent("Crucible-Logs-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// The newest lines of the app log for an on-device viewer, with counts for the whole log.
package struct LogTail: Equatable, Sendable {
    package static let defaultLineLimit = 200

    package let lines: [String]
    package let totalLineCount: Int
    package let errorCount: Int
    package let byteCount: Int

    package var isEmpty: Bool { lines.isEmpty }

    package static func read(maxLines: Int = defaultLineLimit) async -> LogTail {
        let files = LogFiles.live
        return await Task.detached(priority: .userInitiated) {
            read(files: files, maxLines: maxLines)
        }.value
    }

    /// Whether `line` was logged at error or fault level.
    package static func isError(_ line: String) -> Bool {
        line.contains("[ERROR]") || line.contains("[FAULT]")
    }

    /// Previous log first, then the current one, so a log that just rotated still shows context.
    static func read(files: LogFiles, maxLines: Int) -> LogTail {
        let previous = (try? String(contentsOf: files.previous, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: files.current, encoding: .utf8)) ?? ""
        let all = (previous + "\n" + current).split(whereSeparator: \.isNewline).map(String.init)
        let errors = all.filter(isError).count
        return LogTail(
            lines: Array(all.suffix(max(0, maxLines))),
            totalLineCount: all.count,
            errorCount: errors,
            byteCount: previous.utf8.count + current.utf8.count
        )
    }
}

/// Measures the on-disk poster and backdrop cache.
package enum ImageCacheMeter {
    package static func totalBytes() async -> Int64 {
        await Task.detached(priority: .utility) { measure() }.value
    }

    static func measure(root: URL? = nil) -> Int64 {
        guard let root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("Images", isDirectory: true) else { return 0 }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    package static func formatted(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Empty"
    }
}

/// The Top Shelf's on-device state: what the app last wrote, what the extension last read, and
/// whether the sandbox granted the App Group this launch.
package struct TopShelfStatus: Sendable {
    package let diagnostics: TopShelfStoreDiagnostics

    package var snapshotLine: String { diagnostics.snapshotSummary }
    package var readLine: String { diagnostics.receiptSummary }

    package static func read() async -> TopShelfStatus {
        await Task.detached(priority: .userInitiated) {
            TopShelfStatus(diagnostics: TopShelfStore.shared.diagnostics)
        }.value
    }
}
