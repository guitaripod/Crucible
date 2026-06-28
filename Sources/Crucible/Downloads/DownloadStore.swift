import Foundation
import os

/// Deterministic on-disk locations for downloaded media. Kept nonisolated so the background
/// URLSession delegate can move a finished temp file synchronously without hopping actors.
enum DownloadPaths {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    static func mediaURL(ratingKey: String, ext: String) -> URL {
        directory.appendingPathComponent("\(ratingKey).\(ext)")
    }

    /// Folder holding a downloaded HLS asset (local playlist + segments) for one item.
    static func assetDir(ratingKey: String) -> URL {
        directory.appendingPathComponent(ratingKey, isDirectory: true)
    }

    static func playlistURL(ratingKey: String) -> URL {
        assetDir(ratingKey: ratingKey).appendingPathComponent("index.m3u8")
    }

    static func posterURL(ratingKey: String) -> URL {
        directory.appendingPathComponent("\(ratingKey).jpg")
    }

    static func resumeURL(ratingKey: String) -> URL {
        directory.appendingPathComponent("\(ratingKey).resume")
    }

    @discardableResult
    static func ensureDirectory() -> Bool {
        let dir = directory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                log.error("Create downloads dir failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        excludeFromBackup(dir)
        return true
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Synchronously moves a finished temp download to its final location, replacing any existing file.
    /// Returns the destination URL on success. Safe to call from the URLSession delegate queue.
    static func commit(tempURL: URL, ratingKey: String, ext: String) -> URL? {
        ensureDirectory()
        let dest = mediaURL(ratingKey: ratingKey, ext: ext)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tempURL, to: dest)
            excludeFromBackup(dest)
            return dest
        } catch {
            log.error("Commit download \(ratingKey, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Owns the on-disk manifest, posters and resume blobs. The in-memory authoritative list lives
/// on `DownloadManager` (MainActor); this actor performs all file I/O off the main thread.
actor DownloadStore {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func load() -> [DownloadItem] {
        DownloadPaths.ensureDirectory()
        guard let data = try? Data(contentsOf: DownloadPaths.manifestURL) else { return [] }
        do {
            return try decoder.decode([DownloadItem].self, from: data)
        } catch {
            Self.log.error("Manifest decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ items: [DownloadItem]) {
        DownloadPaths.ensureDirectory()
        do {
            let data = try encoder.encode(items)
            try data.write(to: DownloadPaths.manifestURL, options: .atomic)
        } catch {
            Self.log.error("Manifest save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func savePoster(_ data: Data, ratingKey: String) {
        DownloadPaths.ensureDirectory()
        let url = DownloadPaths.posterURL(ratingKey: ratingKey)
        try? data.write(to: url, options: .atomic)
        DownloadPaths.excludeFromBackup(url)
    }

    func deletePoster(ratingKey: String) {
        try? FileManager.default.removeItem(at: DownloadPaths.posterURL(ratingKey: ratingKey))
    }

    func deleteFiles(ratingKey: String, ext: String) {
        let fm = FileManager.default
        for url in [
            DownloadPaths.mediaURL(ratingKey: ratingKey, ext: ext),
            DownloadPaths.posterURL(ratingKey: ratingKey),
            DownloadPaths.resumeURL(ratingKey: ratingKey),
        ] {
            try? fm.removeItem(at: url)
        }
    }

    func saveResumeData(_ data: Data, ratingKey: String) {
        DownloadPaths.ensureDirectory()
        let url = DownloadPaths.resumeURL(ratingKey: ratingKey)
        try? data.write(to: url, options: .atomic)
        DownloadPaths.excludeFromBackup(url)
    }

    func loadResumeData(ratingKey: String) -> Data? {
        try? Data(contentsOf: DownloadPaths.resumeURL(ratingKey: ratingKey))
    }

    func deleteResumeData(ratingKey: String) {
        try? FileManager.default.removeItem(at: DownloadPaths.resumeURL(ratingKey: ratingKey))
    }

    /// Sum of all bytes the downloads directory actually occupies on disk.
    func bytesOnDisk() -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: DownloadPaths.directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for url in contents {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Free space available on the volume backing the downloads directory. Volume capacity is a property
    /// of the volume, so it is read from a guaranteed-existing parent directory when the downloads
    /// directory has not been created yet.
    func availableCapacityBytes() -> Int64 {
        let probe = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Removes any media/poster files not referenced by the manifest (e.g. interrupted moves).
    func reconcile(keepRatingKeys: Set<String>) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: DownloadPaths.directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent != "manifest.json" {
            let key = url.deletingPathExtension().lastPathComponent
            if !keepRatingKeys.contains(key) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
