import Foundation

final class LogFileWriter: @unchecked Sendable {
    static let shared = LogFileWriter()

    private let queue = DispatchQueue(label: "com.guitaripod.crucible.log", qos: .utility)
    private let maxBytes: UInt64 = 512 * 1024
    private let currentURL: URL
    private let previousURL: URL

    var currentPath: String { currentURL.path }

    private init() {
        let fileManager = FileManager.default
        let logsDir = (try? fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        currentURL = logsDir.appendingPathComponent("crucible.log")
        previousURL = logsDir.appendingPathComponent("crucible.previous.log")
    }

    func write(_ line: String) {
        queue.async { [self] in append(line) }
    }

    func writeSync(_ line: String) {
        queue.sync { [self] in append(line) }
    }

    private func append(_ line: String) {
        let fileManager = FileManager.default
        let data = Data((line + "\n").utf8)
        rotateIfNeeded(incoming: UInt64(data.count))
        if let handle = try? FileHandle(forWritingTo: currentURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            fileManager.createFile(atPath: currentURL.path, contents: data)
        }
    }

    private func rotateIfNeeded(incoming: UInt64) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: currentURL.path) else {
            fileManager.createFile(atPath: currentURL.path, contents: nil)
            return
        }
        let size = ((try? fileManager.attributesOfItem(atPath: currentURL.path))?[.size] as? UInt64) ?? 0
        if size + incoming > maxBytes {
            try? fileManager.removeItem(at: previousURL)
            try? fileManager.moveItem(at: currentURL, to: previousURL)
            fileManager.createFile(atPath: currentURL.path, contents: nil)
        }
    }
}
