import Foundation
import os

enum HLSDownloadError: Error, LocalizedError {
    case badPlaylist
    case noSegments
    case segmentFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badPlaylist: return "Could not read the stream playlist"
        case .noSegments: return "The stream has no segments"
        case .segmentFailed(let s): return "Download failed at \(s)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Downloads a Plex HLS transcode to a local, self-contained playlist + segment folder, playable
/// offline via AVPlayer. Segments are fetched strictly in order, which matches Plex's on-demand
/// transcoder (no seek thrashing). Re-running skips already-downloaded segments, so pause/resume and
/// cross-launch recovery resume cheaply; the master is re-fetched each run to mint a fresh session.
enum HLSDownloader {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")
    private static let segmentRetries = 3
    private static let maxSessionRefreshes = 12

    struct Result: Sendable {
        let totalBytes: Int64
        let segmentCount: Int
    }

    static func download(
        masterURL: URL,
        ratingKey: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DownloadPaths.excludeFromBackup(dir)

        var resolved = try await resolve(masterURL: masterURL, dir: dir)
        let total = resolved.fetchList.count
        var refreshes = 0
        var i = 0
        while i < resolved.fetchList.count {
            try Task.checkCancellation()
            let name = resolved.fetchList[i]
            let dest = dir.appendingPathComponent(localName(for: name))
            if FileManager.default.fileExists(atPath: dest.path), fileSize(dest) > 0 {
                i += 1
                onProgress(Double(i) / Double(total))
                continue
            }
            guard let segURL = URL(string: name, relativeTo: resolved.base)?.absoluteURL else {
                throw HLSDownloadError.segmentFailed(name)
            }
            do {
                try await downloadSegment(segURL, to: dest)
                i += 1
                onProgress(Double(i) / Double(total))
            } catch is CancellationError {
                throw HLSDownloadError.cancelled
            } catch HLSDownloadError.cancelled {
                throw HLSDownloadError.cancelled
            } catch {
                refreshes += 1
                guard refreshes <= maxSessionRefreshes else { throw HLSDownloadError.segmentFailed(name) }
                log.notice("Refreshing Plex session after failure at \(name, privacy: .public) (refresh \(refreshes))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                resolved = try await resolve(masterURL: masterURL, dir: dir)
            }
        }

        let size = directorySize(dir)
        log.notice("HLS download complete \(ratingKey, privacy: .public) segments=\(total) bytes=\(size)")
        return Result(totalBytes: size, segmentCount: total)
    }

    private struct Resolved {
        let base: URL
        let fetchList: [String]
    }

    /// Fetches the master + media playlist (minting a fresh Plex transcode session each call), writes
    /// the local playlist, and returns the segment base URL + ordered fetch list. Called again on
    /// failure so a dead/idle-timed-out session is replaced transparently.
    private static func resolve(masterURL: URL, dir: URL) async throws -> Resolved {
        let masterBody = try await fetchText(masterURL)
        guard let mediaLine = firstURI(in: masterBody),
              let mediaURL = URL(string: mediaLine, relativeTo: masterURL)?.absoluteURL else {
            throw HLSDownloadError.badPlaylist
        }
        let mediaBody = try await fetchText(mediaURL)
        let base = mediaURL.deletingLastPathComponent()

        let segments = segmentURIs(in: mediaBody)
        guard !segments.isEmpty else { throw HLSDownloadError.noSegments }

        let playlist = rewritePlaylist(mediaBody)
        try playlist.data(using: .utf8)?.write(to: dir.appendingPathComponent("index.m3u8"), options: .atomic)

        var fetchList: [String] = []
        if let initURI = mapURI(in: mediaBody) { fetchList.append(initURI) }
        fetchList.append(contentsOf: segments)
        return Resolved(base: base, fetchList: fetchList)
    }

    // MARK: - Networking

    private static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HLSDownloadError.badPlaylist
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func downloadSegment(_ url: URL, to dest: URL) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                    throw HLSDownloadError.segmentFailed(url.lastPathComponent)
                }
                try data.write(to: dest, options: .atomic)
                return
            } catch is CancellationError {
                throw HLSDownloadError.cancelled
            } catch {
                attempt += 1
                if attempt >= segmentRetries { throw HLSDownloadError.segmentFailed(url.lastPathComponent) }
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 1_000_000_000))
            }
        }
    }

    // MARK: - Playlist parsing

    private static func firstURI(in playlist: String) -> String? {
        playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func segmentURIs(in playlist: String) -> [String] {
        playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func mapURI(in playlist: String) -> String? {
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MAP:") else { continue }
            guard let range = line.range(of: "URI=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<end])
        }
        return nil
    }

    /// Rewrites the remote media playlist into a local one: drops the no-cache hint, ensures a VOD
    /// type, and points every URI at the local segment filename it was saved under.
    private static func rewritePlaylist(_ playlist: String) -> String {
        var out = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "#EXTM3U" || line.hasPrefix("#EXT-X-VERSION") || line.hasPrefix("#EXT-X-PLAYLIST-TYPE") { continue }
            if line.hasPrefix("#EXT-X-ALLOW-CACHE") { continue }
            if line.hasPrefix("#EXT-X-MAP:") {
                out.append(rewriteMapLine(line))
            } else if line.hasPrefix("#") {
                out.append(line)
            } else {
                out.append(localName(for: line))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func rewriteMapLine(_ line: String) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<end])
        return "#EXT-X-MAP:URI=\"\(localName(for: uri))\""
    }

    /// Local filename for a (possibly query-bearing) segment URI; the on-disk name must match what
    /// the rewritten playlist references.
    private static func localName(for uri: String) -> String {
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: - Disk

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
