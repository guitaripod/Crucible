import Foundation
@testable import Crucible

/// Writes a download manifest (plus poster images) before the app starts so the Downloads screens
/// render a realistic library without running the download engine.
enum DownloadSeeder {
    struct Spec {
        let ratingKey: String
        let state: DownloadState
        let progress: Double
        let watched: Double
        let gigabytes: Double
        let ageDays: Double
    }

    static func seed(base: URL, specs: [Spec]) {
        DownloadPaths.ensureDirectory()
        var items = [DownloadItem]()
        for spec in specs {
            guard let metadata = fetchMetadata(base: base, ratingKey: spec.ratingKey) else { continue }
            let durationMs = metadata.duration ?? 2_400_000
            let completed = spec.state == .completed
            let bytes = Int64(spec.gigabytes * 1_073_741_824)
            let created = Date().addingTimeInterval(-spec.ageDays * 86_400)
            let item = DownloadItem(
                ratingKey: spec.ratingKey,
                mediaType: metadata.mediaType,
                title: metadata.title,
                showTitle: metadata.grandparentTitle,
                grandparentRatingKey: metadata.grandparentRatingKey,
                parentRatingKey: metadata.parentRatingKey,
                seasonNumber: metadata.parentIndex,
                episodeNumber: metadata.index,
                year: metadata.year,
                durationMs: durationMs,
                summary: metadata.summary,
                plexThumbPath: metadata.grandparentThumb ?? metadata.thumb,
                quality: .high,
                isTranscoded: true,
                fileExtension: "movpkg",
                hlsRelativePath: nil,
                state: spec.state,
                progress: completed ? 1 : spec.progress,
                totalBytes: completed ? bytes : 0,
                downloadedBytes: completed ? bytes : Int64(Double(bytes) * spec.progress),
                estimatedBytes: bytes,
                errorMessage: nil,
                createdAt: created,
                completedAt: completed ? created : nil,
                viewOffsetMs: Int(Double(durationMs) * spec.watched),
                markers: []
            )
            items.append(item)
            if completed { writePlaylist(ratingKey: spec.ratingKey) }
            savePoster(base: base, metadata: metadata, ratingKey: spec.ratingKey)
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: DownloadPaths.manifestURL, options: .atomic)
    }

    private static func writePlaylist(ratingKey: String) {
        let directory = DownloadPaths.assetDir(ratingKey: ratingKey)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
        try? playlist.write(to: DownloadPaths.playlistURL(ratingKey: ratingKey), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("seg0.ts").path, contents: Data([0]))
    }

    private static func request(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("mock-token", forHTTPHeaderField: "X-Plex-Token")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return result
    }

    private static func fetchMetadata(base: URL, ratingKey: String) -> PlexMetadata? {
        guard let data = request(base.appendingPathComponent("library/metadata/\(ratingKey)")),
              let response = try? JSONDecoder().decode(PlexResponse.self, from: data) else { return nil }
        return response.MediaContainer.Metadata?.first
    }

    private static func savePoster(base: URL, metadata: PlexMetadata, ratingKey: String) {
        guard let path = metadata.grandparentThumb ?? metadata.thumb else { return }
        var components = URLComponents(url: base.appendingPathComponent("photo/:/transcode"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: path), URLQueryItem(name: "width", value: "300")]
        guard let url = components?.url, let data = request(url) else { return }
        try? data.write(to: DownloadPaths.posterURL(ratingKey: ratingKey), options: .atomic)
    }
}
