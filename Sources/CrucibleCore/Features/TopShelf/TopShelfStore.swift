import Foundation

/// Reads and writes the Top Shelf snapshot in the App Group container shared by the app and its
/// Top Shelf extension.
package struct TopShelfStore: Sendable {
    package static let appGroupIdentifier = "group.com.guitaripod.crucible"
    static let maxReadBytes = 256 * 1024

    private let directory: URL?

    package init(directory: URL?) {
        self.directory = directory
    }

    package static var shared: TopShelfStore {
        TopShelfStore(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier))
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent("topshelf.json")
    }

    /// Nil when there is no snapshot, it is too large, unreadable or from another schema.
    package func load() -> TopShelfSnapshot? {
        guard let url = fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxReadBytes,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data),
              snapshot.schema == TopShelfSnapshot.schemaVersion
        else { return nil }
        return snapshot
    }

    /// Returns false when there is no shared container or the write failed.
    @discardableResult
    package func save(_ snapshot: TopShelfSnapshot) -> Bool {
        guard let url = fileURL else {
            AppLogger.error("Top Shelf: no App Group container for \(Self.appGroupIdentifier)", .persistence)
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            return true
        } catch {
            AppLogger.error("Top Shelf snapshot save failed: \(error.localizedDescription)", .persistence)
            return false
        }
    }

    package func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
