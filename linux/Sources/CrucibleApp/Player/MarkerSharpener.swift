import CrucibleCore
import Foundation
import MidgarCore

/// Moves a title's intro marker onto the picture's own edges (`MarkerSnap`): ffmpeg reads a few seconds of the file around
/// the marker's start and end, small and without sound, and reports its cuts and blacks. A system without ffmpeg, or a read
/// that fails or takes too long, leaves the server's marker as it is. What was found is kept for the session by title.
enum MarkerSharpener {
    @MainActor private static var known: [String: SkipMarker] = [:]

    /// The markers of `item` with its intro sharpened, or nil when nothing changed.
    static func sharpen(_ markers: [SkipMarker], ratingKey: String, partURL: URL) async -> [SkipMarker]? {
        guard let intro = markers.first(where: { $0.kind == .intro && !$0.fromChapter }) else { return nil }
        let key = "\(ratingKey)|\(intro.startSecs)|\(intro.endSecs)"
        let refined: SkipMarker
        if let cached = await known[key] {
            refined = cached
        } else {
            guard let ffmpeg = ffmpegPath else { return nil }
            async let start = edges(ffmpeg: ffmpeg, url: partURL, from: intro.startSecs - MarkerSnap.startWindow.before,
                                    length: MarkerSnap.startWindow.before + MarkerSnap.startWindow.after)
            async let end = edges(ffmpeg: ffmpeg, url: partURL, from: intro.endSecs - MarkerSnap.endWindow.before,
                                  length: MarkerSnap.endWindow.before + MarkerSnap.endWindow.after)
            guard let startEdges = await start, let endEdges = await end else { return nil }
            refined = MarkerSnap.refined(intro, start: startEdges, end: endEdges)
            await MainActor.run { known[key] = refined }
            MidgarLog.notice("Intro of ratingKey=\(ratingKey) sharpened from \(intro.startSecs)–\(intro.endSecs) to \(refined.startSecs)–\(refined.endSecs)",
                             category: .playback)
        }
        guard refined != intro else { return nil }
        return markers.map { $0 == intro ? refined : $0 }
    }

    private static let ffmpegPath: String? = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/app/bin/ffmpeg"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// The cuts and blacks ffmpeg finds in `length` seconds of `url` read from `from`, or nil when it could not tell.
    private static func edges(ffmpeg: String, url: URL, from: Double, length: Double) async -> MarkerSnap.Edges? {
        let offset = max(0, from)
        let arguments = ["-hide_banner", "-nostdin", "-loglevel", "info", "-ss", String(format: "%.3f", offset), "-t", String(format: "%.3f", length),
                         "-i", url.absoluteString, "-an", "-sn", "-dn",
                         "-vf", "scale=160:-2,scdet=t=8,blackdetect=d=0.04:pix_th=0.1", "-f", "null", "-"]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: MarkerSnap.edges(fromFFmpeg: String(decoding: data, as: UTF8.self), offset: offset))
            }
        }
    }
}
