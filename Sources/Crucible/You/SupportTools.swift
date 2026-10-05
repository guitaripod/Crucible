import UIKit

/// Builds the temporary text file behind "Share Diagnostic Logs".
@MainActor
enum DiagnosticLogExporter {
    static func export() async -> URL? {
        LogFileWriter.shared.writeSync("Diagnostics export requested")
        let header = reportHeader()
        let currentPath = LogFileWriter.shared.currentPath
        return await Task.detached(priority: .userInitiated) {
            assemble(header: header, currentPath: currentPath)
        }.value
    }

    private static func reportHeader() -> String {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return [
            "Crucible \(version) (\(build))",
            "\(device.systemName) \(device.systemVersion) · \(device.model)",
            "Exported \(ISO8601DateFormatter().string(from: Date()))",
        ].joined(separator: "\n")
    }

    private nonisolated static func assemble(header: String, currentPath: String) -> URL? {
        let currentURL = URL(fileURLWithPath: currentPath)
        let previousURL = currentURL.deletingLastPathComponent().appendingPathComponent("crucible.previous.log")
        let previous = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
        guard !previous.isEmpty || !current.isEmpty else { return nil }

        var report = header + "\n"
        if !previous.isEmpty { report += "\n=== Previous log ===\n" + previous }
        if !current.isEmpty { report += "\n=== Current log ===\n" + current }

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Crucible-Logs-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Measures the on-disk poster and backdrop cache.
enum ImageCacheMeter {
    static func totalBytes() async -> Int64 {
        await Task.detached(priority: .utility) { measure() }.value
    }

    private nonisolated static func measure() -> Int64 {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let root = caches.appendingPathComponent("Images", isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Empty"
    }
}
