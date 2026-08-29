import Foundation
import os

/// Trimmed, Codable projection of a Home rail card — just enough to repaint the Home screen in
/// frame 1 on a cold launch, before the /hubs network call returns.
struct HomeCardSnapshot: Codable, Sendable {
    let ratingKey: String
    let type: String?
    let title: String
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let grandparentThumb: String?
    let parentRatingKey: String?
    let thumb: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let viewOffset: Int?
    let duration: Int?
    let viewCount: Int?
    let bucket: String
}

struct HomeSnapshot: Codable, Sendable {
    let schema: Int
    let machineIdentifier: String
    let savedAt: Int
    let cards: [HomeCardSnapshot]
}

enum HomeSnapshotStore {
    static let schemaVersion = 1
    private static let maxReadBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.guitaripod.crucible.homesnapshot")
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "persistence")

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Home", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("home-snapshot.json")
    }

    /// Synchronous, size-guarded read used on the launch path. Returns nil on any problem so the
    /// caller falls back to the skeleton/network.
    static func loadSync() -> HomeSnapshot? {
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

    static func save(_ snapshot: HomeSnapshot) {
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

    static func destroy() {
        queue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
