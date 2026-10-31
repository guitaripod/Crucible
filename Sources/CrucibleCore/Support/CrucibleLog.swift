import Foundation
import MidgarCore

/// Crucible's log file and the categories its lines are filed under, on top of MidgarLog.
package enum CrucibleLog {
    /// The file every Crucible process appends to, kept from the retired per-app logger so the ios-device-logs workflow still finds it.
    package static let fileName = "crucible.log"

    /// `Library/Logs` in the process's container, where MidgarLog writes.
    package static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
    }

    /// Opens the log file. Call first thing in every process (app, Top Shelf) so nothing before it is lost.
    package static func configure() {
        MidgarLog.configure(subsystem: "com.guitaripod.crucible", fileName: fileName)
    }
}

extension MidgarLog.Category {
    package static let lifecycle = MidgarLog.Category("lifecycle")
    package static let networking = MidgarLog.Category("networking")
    package static let playback = MidgarLog.Category("playback")
    package static let persistence = MidgarLog.Category("persistence")
    package static let stats = MidgarLog.Category("stats")
    package static let store = MidgarLog.Category("store")
}
