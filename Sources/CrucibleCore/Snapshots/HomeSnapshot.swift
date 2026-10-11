import Foundation
import os

/// Trimmed, Codable projection of a Home rail card — just enough to repaint the Home screen in
/// frame 1 on a cold launch, before the /hubs network call returns.
package struct HomeCardSnapshot: Codable, Sendable {
    package let ratingKey: String
    package let type: String?
    package let title: String
    package let grandparentTitle: String?
    package let grandparentRatingKey: String?
    package let grandparentThumb: String?
    package let parentRatingKey: String?
    package let thumb: String?
    package let parentIndex: Int?
    package let index: Int?
    package let year: Int?
    package let viewOffset: Int?
    package let duration: Int?
    package let viewCount: Int?
    package let bucket: String
    package var art: String? = nil
    package var grandparentArt: String? = nil
    package var librarySectionID: Int? = nil
}

package struct HomeSnapshot: Codable, Sendable {
    package let schema: Int
    package let machineIdentifier: String
    package let savedAt: Int
    package let cards: [HomeCardSnapshot]

    package init(schema: Int, machineIdentifier: String, savedAt: Int, cards: [HomeCardSnapshot]) {
        self.schema = schema
        self.machineIdentifier = machineIdentifier
        self.savedAt = savedAt
        self.cards = cards
    }
}

package enum HomeSnapshotStore {
    package static let schemaVersion = 2
    private static let maxReadBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.guitaripod.crucible.homesnapshot")
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "persistence")

    private static var directory: URL {
        AppPlatform.persistentDirectory
            .appendingPathComponent("Home", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("home-snapshot.json")
    }

    /// Synchronous, size-guarded read used on the launch path. Returns nil on any problem so the
    /// caller falls back to the skeleton/network.
    package static func loadSync() -> HomeSnapshot? {
        let url = fileURL
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxReadBytes else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(HomeSnapshot.self, from: data), snapshot.schema == schemaVersion else {
            return nil
        }
        return snapshot
    }

    package static func save(_ snapshot: HomeSnapshot) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
                var mutable = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? mutable.setResourceValues(values)
            } catch {
                log.error("Home snapshot save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    package static func destroy() {
        queue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
