import Foundation
import os

/// Persistent second-tier image cache under Library/Caches (auto-excluded from backup, purgeable
/// by the OS under storage pressure). Stores the raw transcoded JPEG bytes verbatim so a cold
/// launch renders posters from disk instead of re-fetching them. All file I/O runs on a private
/// concurrent queue (sync reads, barrier writes) so the ImageLoader actor never blocks on disk.
final class DiskImageCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.guitaripod.crucible.diskimage", attributes: .concurrent)
    private let root: URL
    private let maxBytes: Int
    private let log = Logger(subsystem: "com.guitaripod.crucible", category: "image")
    private var writesSinceTrim = 0

    init(namespace: String, maxBytes: Int = 256 * 1024 * 1024) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = base
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(Self.sanitize(namespace), isDirectory: true)
        self.maxBytes = maxBytes
        queue.async(flags: .barrier) { [root] in
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        trim()
    }

    func read(key: String) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                let url = fileURL(for: key)
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                var values = URLResourceValues()
                values.contentAccessDate = Date()
                var mutable = url
                try? mutable.setResourceValues(values)
                continuation.resume(returning: data)
            }
        }
    }

    func write(_ data: Data, key: String) {
        guard !data.isEmpty else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let url = fileURL(for: key)
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            writesSinceTrim += 1
            if writesSinceTrim >= 96 {
                writesSinceTrim = 0
                trimLocked()
            }
        }
    }

    func clear() {
        queue.async(flags: .barrier) { [root] in
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    private func trim() {
        queue.async(flags: .barrier) { [weak self] in
            self?.trimLocked()
        }
    }

    /// Evicts least-recently-accessed files until the cache is under the size ceiling. Must run on
    /// the barrier queue.
    private func trimLocked() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int, accessed: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentAccessDate ?? .distantPast))
        }

        guard total > maxBytes else { return }
        files.sort { $0.accessed < $1.accessed }
        var overage = total - maxBytes
        for file in files {
            if overage <= 0 { break }
            try? FileManager.default.removeItem(at: file.url)
            overage -= file.size
        }
    }

    private func fileURL(for key: String) -> URL {
        let name = Self.stableHash(key)
        let shard = String(name.prefix(2))
        return root.appendingPathComponent(shard, isDirectory: true).appendingPathComponent(name + ".img")
    }

    /// Deterministic 128-bit hex digest (two independent 64-bit hashes) — collision-safe for a
    /// per-device image cache without pulling in a crypto framework.
    private static func stableHash(_ string: String) -> String {
        var fnv: UInt64 = 0xcbf29ce484222325
        var djb: UInt64 = 5381
        for byte in string.utf8 {
            fnv = (fnv ^ UInt64(byte)) &* 0x100000001b3
            djb = ((djb << 5) &+ djb) &+ UInt64(byte)
        }
        return String(format: "%016llx%016llx", fnv, djb)
    }

    private static func sanitize(_ namespace: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = namespace.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? "default" : cleaned
    }
}
