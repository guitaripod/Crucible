import Foundation

/// Where the bundled content lives: the catalogue, the artwork, the clip and its HLS cut.
struct DemoAssets: Sendable {
    static let bundleFolder = "Data"

    let root: URL

    static func bundled() throws -> DemoAssets {
        guard let url = Bundle.module.url(forResource: bundleFolder, withExtension: nil) else { throw DemoLibraryError.resourcesMissing }
        return DemoAssets(root: url)
    }

    var catalogue: URL { root.appendingPathComponent("library.json") }
    var clip: URL { root.appendingPathComponent("video/clip.mp4") }

    func image(_ name: String) -> URL {
        root.appendingPathComponent("images").appendingPathComponent(name)
    }

    func stream(_ name: String) -> URL {
        root.appendingPathComponent("video/hls").appendingPathComponent(name)
    }

    /// The master playlist the transcode start answers with: one rendition, which points at the media playlist of the session.
    func masterPlaylist(session: String) -> String {
        let bandwidth = bandwidthEstimate
        return """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(bandwidth),RESOLUTION=1280x720,FRAME-RATE=25.000,CODECS="avc1.640020,mp4a.40.2"
        session/\(session)/base/index.m3u8

        """
    }

    private var bandwidthEstimate: Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 0
        return max(400_000, size * 8 / 30)
    }

    static func contentType(forFile name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4", "m4s": return "video/mp4"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
