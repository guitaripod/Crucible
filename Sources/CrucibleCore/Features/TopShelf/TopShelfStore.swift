import Foundation
import MidgarCore

/// Reads and writes the Top Shelf snapshot in the App Group container shared by the app and its
/// Top Shelf extension.
///
/// tvOS refuses writes at the root of the container on real hardware (the sandbox logs
/// `deny(1) file-write-create`), so the snapshot lives in `Library/Caches`, the one directory inside
/// the group the sandbox allows. The root stays as a fallback so a snapshot written by an earlier
/// version is still read and cleaned up.
package struct TopShelfStore: Sendable {
    package static let appGroupIdentifier = "group.com.guitaripod.crucible"
    static let maxReadBytes = 256 * 1024
    private static let snapshotName = "topshelf.json"
    private static let receiptName = "topshelf-read.json"

    private let container: URL?

    package init(directory: URL?) {
        self.container = directory
    }

    package static var shared: TopShelfStore {
        TopShelfStore(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier))
    }

    /// Where the snapshot is written and read, most preferred first.
    package var directories: [URL] {
        guard let container else { return [] }
        return [container.appendingPathComponent("Library/Caches", isDirectory: true), container]
    }

    package var containerPath: String? {
        container?.path
    }

    /// Every candidate file path, for Diagnostics.
    package var snapshotPaths: [String] {
        directories.map { $0.appendingPathComponent(Self.snapshotName).path }
    }

    package var existingSnapshotPath: String? {
        directories.lazy
            .map { $0.appendingPathComponent(Self.snapshotName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .path
    }

    /// The first candidate directory the sandbox lets this process write to. tvOS answers the
    /// container URL even when a write there is denied, so a probe is the only way to tell a
    /// sandbox denial apart from an empty shelf.
    package func writableDirectory() -> URL? {
        for directory in directories {
            let url = directory.appendingPathComponent("topshelf-probe.tmp")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("probe".utf8).write(to: url)
                try? FileManager.default.removeItem(at: url)
                return directory
            } catch {
                continue
            }
        }
        return nil
    }

    /// Nil when there is no snapshot, it is too large, unreadable or from another schema.
    package func load() -> TopShelfSnapshot? {
        for directory in directories {
            let url = directory.appendingPathComponent(Self.snapshotName)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            guard size <= Self.maxReadBytes else {
                MidgarLog.error("Top Shelf snapshot at \(url.path) is \(size) bytes, over the read limit", category: .persistence)
                continue
            }
            guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data) else {
                MidgarLog.error("Top Shelf snapshot at \(url.path) could not be read", category: .persistence)
                continue
            }
            guard snapshot.schema == TopShelfSnapshot.schemaVersion else { continue }
            return snapshot
        }
        return nil
    }

    /// Returns false when there is no shared container or every write failed.
    @discardableResult
    package func save(_ snapshot: TopShelfSnapshot) -> Bool {
        guard container != nil else {
            MidgarLog.error("Top Shelf: no App Group container for \(Self.appGroupIdentifier)", category: .persistence)
            return false
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        for directory in directories {
            let url = directory.appendingPathComponent(Self.snapshotName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    try data.write(to: url)
                }
                removeStaleCopy(keeping: url)
                return true
            } catch {
                logWriteFailure(error, at: url)
            }
        }
        return false
    }

    /// Removes every copy, including one a previous version wrote at the container root.
    package func clear() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.snapshotName))
        }
    }

    @discardableResult
    package func saveReceipt(_ receipt: TopShelfReceipt) -> Bool {
        guard let data = try? JSONEncoder().encode(receipt) else { return false }
        let candidates = receiptDirectoryCandidates()
        for directory in candidates {
            let url = directory.appendingPathComponent(Self.receiptName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                return true
            } catch {
                logWriteFailure(error, at: url)
            }
        }
        return false
    }

    package func receipt() -> TopShelfReceipt? {
        for directory in receiptDirectoryCandidates() {
            let url = directory.appendingPathComponent(Self.receiptName)
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(TopShelfReceipt.self, from: data),
                  receipt.schema == TopShelfReceipt.schemaVersion
            else { continue }
            return receipt
        }
        return nil
    }

    /// The snapshot's own directory first, so the receipt and the content it describes sit together.
    private func receiptDirectoryCandidates() -> [URL] {
        guard let existing = existingSnapshotPath.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) else {
            return directories
        }
        return [existing] + directories.filter { $0.path != existing.path }
    }

    private func removeStaleCopy(keeping url: URL) {
        guard let container, url.deletingLastPathComponent().path != container.path else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(Self.snapshotName))
    }

    private func logWriteFailure(_ error: Error, at url: URL) {
        let failure = error as NSError
        MidgarLog.error(
            "Top Shelf write failed at \(url.path): \(failure.domain) \(failure.code) — \(failure.localizedDescription)",
            category: .persistence
        )
    }

    package var diagnostics: TopShelfStoreDiagnostics {
        TopShelfStoreDiagnostics(
            containerPath: containerPath,
            writablePath: writableDirectory()?.path,
            snapshotPath: existingSnapshotPath,
            snapshot: load(),
            receipt: receipt()
        )
    }
}

/// Everything Diagnostics needs to explain the Top Shelf's state on the Apple TV.
package struct TopShelfStoreDiagnostics: Sendable {
    package let containerPath: String?
    package let writablePath: String?
    package let snapshotPath: String?
    package let snapshot: TopShelfSnapshot?
    package let receipt: TopShelfReceipt?

    package var hasContainer: Bool {
        containerPath != nil
    }

    package var snapshotSummary: String {
        guard hasContainer else { return "No App Group" }
        guard writablePath != nil else { return "No write access" }
        guard let snapshot else { return "No snapshot" }
        return "\(snapshot.itemCount) items · \(Self.time(snapshot.savedAt))"
    }

    package var receiptSummary: String {
        guard let receipt else { return "Never" }
        return "\(receipt.itemCount) items · \(Self.time(receipt.readAt))"
    }

    package var logSummary: String {
        "Top Shelf: container=\(containerPath ?? "none") write=\(writablePath ?? "denied") snapshot=\(snapshotPath ?? "none")"
    }

    private static func time(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .abbreviated, time: .shortened)
    }
}
