import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// Web videos being saved to this machine. yt-dlp writes each as one Matroska file into Crucible's folder of the
/// viewer's Videos, with its chapters and the publisher's subtitles inside; the library remembers which file is which
/// video, and a downloaded video plays from its file.
@MainActor
final class WebDownloads {
    static let shared = WebDownloads()
    /// Posted when a download starts, ends or fails.
    static let didChange = Notification.Name("org.guitaripod.Crucible.WebDownloadsDidChange")

    static var downloadTitle: String { String(localized: "Download", comment: "Web video menu: save the video to this computer") }
    static var cancelTitle: String { String(localized: "Cancel Download", comment: "Web video menu") }
    static var deleteTitle: String { String(localized: "Delete Download", comment: "Web video menu: remove the saved file") }
    static var listTitle: String { String(localized: "Downloads", comment: "The list of web videos saved to this computer") }
    static var downloadingTitle: String { String(localized: "Downloading…", comment: "Chip shown while a web video is being saved") }

    private var running: [String: Task<Void, Never>] = [:]

    var hasRunning: Bool { !running.isEmpty }

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    /// Crucible's folder in the viewer's Videos folder, as `user-dirs.dirs` names it.
    static var folder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        var videos = home.appendingPathComponent("Videos")
        if let dirs = try? String(contentsOf: config.appendingPathComponent("user-dirs.dirs"), encoding: .utf8),
           let line = dirs.split(separator: "\n").first(where: { $0.hasPrefix("XDG_VIDEOS_DIR=") }) {
            let value = line.dropFirst("XDG_VIDEOS_DIR=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { videos = URL(fileURLWithPath: value.replacingOccurrences(of: "$HOME", with: home.path)) }
        }
        return videos.appendingPathComponent("Crucible")
    }

    /// Starts saving `entry`; a failure says why in `window`.
    func start(_ entry: WebEntry, in window: Window?) {
        guard running[entry.id] == nil, WebService.shared.library.download(of: entry.id) == nil else { return }
        let folder = Self.folder
        running[entry.id] = Task { [weak self, weak window] in
            let outcome: Result<String, any Error>
            do {
                outcome = .success(try await WebService.shared.download(entry.url, into: folder))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.running[entry.id] = nil
            switch outcome {
            case .success(let path):
                WebService.shared.library.noteDownload(WebDownload(entry: entry, path: path))
                MidgarLog.notice("A web video was downloaded", category: .lifecycle)
            case .failure(let error) where !(error is CancellationError):
                MidgarLog.error("A web video's download failed: \(error)", category: .networking)
                if let window {
                    AlertView.notice(title: String(localized: "Couldn’t Download", comment: "Alert title when saving a web video failed"),
                                     message: WebService.message(for: error), in: window)
                }
            case .failure:
                break
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func cancel(_ id: String) {
        running[id]?.cancel()
    }

    /// Removes a downloaded video's file and forgets it.
    func delete(_ id: String) {
        guard let download = WebService.shared.library.download(of: id) else { return }
        try? FileManager.default.removeItem(atPath: download.path)
        WebService.shared.library.forgetDownload(id)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
