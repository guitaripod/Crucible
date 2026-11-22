import Foundation
import MidgarCore

/// Crucible's log file and the categories its lines are filed under, on top of MidgarLog.
package enum CrucibleLog {
    /// The file every Crucible process appends to, kept from the retired per-app logger so the ios-device-logs workflow still finds it.
    package static let fileName = "crucible.log"

    /// `Library/Logs` in the process's container, where MidgarLog writes (`Library/Caches/Logs` on tvOS, which lets an app write
    /// nowhere else in Library); on Linux, which has no Library, MidgarLog's `$XDG_STATE_HOME/<process>/logs` (`~/.local/state/crucible/logs`).
    package static var directory: URL {
        #if os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let state = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".local/state", isDirectory: true)
        return state.appendingPathComponent(ProcessInfo.processInfo.processName.lowercased(), isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        #elseif os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        #else
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
        #endif
    }

    /// Opens the log file. Call first thing in every process (app, Top Shelf) so nothing before it is lost.
    package static func configure() {
        MidgarLog.configure(subsystem: "com.guitaripod.crucible", fileName: fileName)
    }

    /// Writes an uncaught Objective-C exception and its stack to the log before the process ends. The handler is made here,
    /// outside any actor, because the exception can be thrown on any thread: one made in an app delegate is the main actor's,
    /// and the runtime stops the process the moment it runs anywhere else, before a line is written. Linux has no
    /// Objective-C runtime; its client flushes the log from its own fatal-signal handler.
    package static func logUncaughtExceptions() {
        #if canImport(Darwin)
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            MidgarLog.fault("Uncaught exception: \(exception.name.rawValue) - \(exception.reason ?? "no reason")\n\(stack)", category: .lifecycle)
            MidgarLog.flush()
        }
        #endif
    }
}

extension MidgarLog.Category {
    package static let lifecycle = MidgarLog.Category("lifecycle")
    package static let networking = MidgarLog.Category("networking")
    package static let playback = MidgarLog.Category("playback")
    package static let persistence = MidgarLog.Category("persistence")
    package static let stats = MidgarLog.Category("stats")
    package static let store = MidgarLog.Category("store")
    package static let liveTV = MidgarLog.Category("livetv")
}
