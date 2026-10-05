import UIKit

/// The single download state machine shared by the movie/episode action row and the episode rows:
/// maps `DownloadManager` state to a `DownloadRingButton` state, performs the ring's tap, and builds
/// the long-press menu that keeps every per-state option (quality, pause, cancel, retry, play offline).
@MainActor
enum DetailDownload {
    static func ringState(for ratingKey: String) -> DownloadRingButton.State {
        guard let item = DownloadManager.shared.item(for: ratingKey) else { return .idle }
        switch item.state {
        case .queued, .waitingForWiFi: return .queued
        case .downloading: return .progress(item.progress)
        case .paused: return .paused(item.progress)
        case .completed: return .completed
        case .failed: return .failed
        }
    }

    /// Tap semantics follow the ring's spoken hints: idle downloads, queued cancels, downloading
    /// pauses, paused/failed resume, and a completed download asks before it is removed.
    static func performTap(for metadata: PlexMetadata, from host: UIViewController, sourceView: UIView?) {
        let key = metadata.id
        guard !key.isEmpty else { return }
        let manager = DownloadManager.shared
        switch manager.item(for: key)?.state {
        case nil:
            Haptics.medium()
            AppLogger.notice("Detail download tapped ratingKey=\(key)", .persistence)
            manager.enqueue(metadata: metadata)
        case .queued?, .waitingForWiFi?:
            Haptics.medium()
            manager.delete(key)
        case .downloading?:
            Haptics.medium()
            manager.pause(key)
        case .paused?, .failed?:
            Haptics.medium()
            manager.resume(key)
        case .completed?:
            confirmRemoval(title: metadata.title, ratingKey: key, from: host, sourceView: sourceView)
        }
    }

    static func confirmRemoval(title: String, ratingKey: String, from host: UIViewController, sourceView: UIView?) {
        let sheet = UIAlertController(
            title: "Remove Download?",
            message: "\u{201C}\(title)\u{201D} will be deleted from this device. You can download it again later.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove Download", style: .destructive) { _ in
            Haptics.medium()
            DownloadManager.shared.delete(ratingKey)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if let sourceView {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            } else {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            }
        }
        host.present(sheet, animated: true)
    }

    static func menu(for metadata: PlexMetadata, onPlayOffline: (() -> Void)?) -> UIMenu {
        let key = metadata.id
        let manager = DownloadManager.shared
        let item = manager.item(for: key)
        switch item?.state {
        case nil:
            let current = Preferences.downloadQuality
            let actions = DownloadQuality.allCases.map { quality in
                UIAction(title: quality.title, subtitle: quality.detail, state: quality == current ? .on : .off) { _ in
                    Haptics.medium()
                    manager.enqueue(metadata: metadata, quality: quality)
                }
            }
            return UIMenu(title: "Download Quality", children: actions)
        case .queued?, .waitingForWiFi?, .downloading?:
            return UIMenu(title: item?.statusLine ?? "", children: [
                UIAction(title: "Pause", image: UIImage(systemName: "pause.fill")) { _ in manager.pause(key) },
                UIAction(title: "Cancel Download", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .paused?:
            return UIMenu(title: item?.statusLine ?? "", children: [
                UIAction(title: "Resume Download", image: UIImage(systemName: "arrow.down.to.line")) { _ in manager.resume(key) },
                UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .failed?:
            return UIMenu(title: item?.errorMessage ?? "Download Failed", children: [
                UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { _ in manager.retry(key) },
                UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .completed?:
            var children: [UIMenuElement] = []
            if let onPlayOffline {
                children.append(UIAction(title: "Play Offline", image: UIImage(systemName: "play.fill")) { _ in onPlayOffline() })
            }
            children.append(UIAction(title: "Delete Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                manager.delete(key)
            })
            return UIMenu(title: item?.statusLine ?? "", children: children)
        }
    }

    static func spokenState(for ratingKey: String) -> String? {
        guard let item = DownloadManager.shared.item(for: ratingKey) else { return nil }
        switch item.state {
        case .queued: return "download queued"
        case .waitingForWiFi: return "download waiting for Wi-Fi"
        case .downloading: return "downloading \(Int((item.progress * 100).rounded())) percent"
        case .paused: return "download paused at \(Int((item.progress * 100).rounded())) percent"
        case .completed: return "downloaded"
        case .failed: return "download failed"
        }
    }
}
