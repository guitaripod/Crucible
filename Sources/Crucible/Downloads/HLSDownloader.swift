import Foundation
import os

enum HLSDownloadError: Error, LocalizedError {
    case badPlaylist
    case noSegments

    var errorDescription: String? {
        switch self {
        case .badPlaylist: return "Could not read the stream playlist"
        case .noSegments: return "The stream has no segments"
        }
    }
}

/// Resolves a Plex HLS transcode into a local, self-contained playlist (`index.m3u8` + the ordered
/// list of segment names to fetch) and mints a fresh transcode session each call. The actual segment
/// bytes are fetched by `DownloadManager` over a background `URLSession`, sequentially (matching
/// Plex's on-demand transcoder), so downloads continue while the app is suspended.
enum HLSDownloader {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    struct Resolved: Sendable {
        /// Base URL the segment names resolve against (the current Plex session directory).
        let base: URL
        /// Ordered fetch list: the `#EXT-X-MAP` init segment (if any) followed by media segments.
        let segments: [String]
    }

    static func resolve(masterURL: URL, ratingKey: String) async throws -> Resolved {
        let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DownloadPaths.excludeFromBackup(dir)

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
        log.notice("Resolved HLS \(ratingKey, privacy: .public) segments=\(fetchList.count)")
        return Resolved(base: base, segments: fetchList)
    }

    /// URL for one segment against the current session base.
    static func segmentURL(name: String, base: URL) -> URL? {
        URL(string: name, relativeTo: base)?.absoluteURL
    }

    /// Local filenames a persisted (rewritten) playlist references: the `#EXT-X-MAP` init segment
    /// (if any) plus every media segment. Lets callers verify an on-disk asset is actually whole —
    /// the playlist itself is written at resolve time, before any segment has been fetched.
    static func referencedLocalNames(inPlaylistAt url: URL) -> [String]? {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var names: [String] = []
        if let initURI = mapURI(in: body) { names.append(localName(for: initURI)) }
        names.append(contentsOf: segmentURIs(in: body).map { localName(for: $0) })
        return names
    }

    /// Local filename for a (possibly query-bearing) segment URI; the on-disk name must match what the
    /// rewritten playlist references.
    static func localName(for uri: String) -> String {
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
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
            guard line.hasPrefix("#EXT-X-MAP:"), let range = line.range(of: "URI=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<end])
        }
        return nil
    }

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
        if !out.contains("#EXT-X-ENDLIST") { out.append("#EXT-X-ENDLIST") }
        return out.joined(separator: "\n") + "\n"
    }

    private static func rewriteMapLine(_ line: String) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        return "#EXT-X-MAP:URI=\"\(localName(for: String(rest[..<end])))\""
    }
}
