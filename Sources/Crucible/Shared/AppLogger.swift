import Foundation
import os

enum AppLogger {
    enum Category: String {
        case lifecycle, networking, playback, persistence, ui
    }

    static func info(_ message: String, _ category: Category) { emit(message, category, .info, "INFO") }
    static func notice(_ message: String, _ category: Category) { emit(message, category, .default, "NOTE") }
    static func error(_ message: String, _ category: Category) { emit(message, category, .error, "ERROR") }
    static func fault(_ message: String, _ category: Category, sync: Bool = false) { emit(message, category, .fault, "FAULT", sync: sync) }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func emit(_ message: String, _ category: Category, _ level: OSLogType, _ tag: String, sync: Bool = false) {
        Logger(subsystem: "com.guitaripod.crucible", category: category.rawValue)
            .log(level: level, "\(message, privacy: .public)")
        let line = "\(timestampFormatter.string(from: Date())) [\(tag)] [\(category.rawValue)] \(message)"
        if sync {
            LogFileWriter.shared.writeSync(line)
        } else {
            LogFileWriter.shared.write(line)
        }
    }
}
