import CrucibleCore
import CrucibleDesign
import MidgarCore
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
            MidgarLog.notice("Detail download tapped ratingKey=\(key)", category: .persistence)
            manager.requestDownload(metadata: metadata)
        case .queued?, .waitingForWiFi?:
            Haptics.medium()
            manager.delete(key)
        case .downloading?:
            Haptics.medium()
            manager.pause(key)
        case .paused?, .failed?:
            Haptics.medium()
            manager.requestResume(key)
        case .completed?:
            confirmRemoval(title: metadata.title, ratingKey: key, from: host, sourceView: sourceView)
        }
    }

    static func confirmRemoval(title: String, ratingKey: String, from host: UIViewController, sourceView: UIView?) {
        let sheet = UIAlertController(
            title: String(localized: "Remove Download?"),
            message: String(localized: "\u{201C}\(title)\u{201D} will be deleted from this device. You can download it again later."),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Remove Download"), style: .destructive) { _ in
            Haptics.medium()
            DownloadManager.shared.delete(ratingKey)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
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

    /// What the download control does next, as a menu bar title.
    static func commandTitle(for ratingKey: String) -> String {
        switch DownloadManager.shared.item(for: ratingKey)?.state {
        case nil: return String(localized: "Download")
        case .queued?, .waitingForWiFi?: return String(localized: "Cancel Download")
        case .downloading?: return String(localized: "Pause Download")
        case .paused?, .failed?: return String(localized: "Resume Download")
        case .completed?: return String(localized: "Remove Download…")
        }
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
                    manager.requestDownload(metadata: metadata, quality: quality)
                }
            }
            return UIMenu(title: String(localized: "Download Quality"), children: actions)
        case .queued?, .waitingForWiFi?, .downloading?:
            return UIMenu(title: item?.statusLine ?? "", children: [
                UIAction(title: String(localized: "Pause"), image: UIImage(systemName: "pause.fill")) { _ in manager.pause(key) },
                UIAction(title: String(localized: "Cancel Download"), image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .paused?:
            return UIMenu(title: item?.statusLine ?? "", children: [
                UIAction(title: String(localized: "Resume Download"), image: UIImage(systemName: "arrow.down.to.line")) { _ in manager.requestResume(key) },
                UIAction(title: String(localized: "Remove Download"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .failed?:
            return UIMenu(title: item?.errorMessage ?? String(localized: "Download Failed"), children: [
                UIAction(title: String(localized: "Retry"), image: UIImage(systemName: "arrow.clockwise")) { _ in manager.requestResume(key) },
                UIAction(title: String(localized: "Remove Download"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    manager.delete(key)
                },
            ])
        case .completed?:
            var children: [UIMenuElement] = []
            if let onPlayOffline {
                children.append(UIAction(title: String(localized: "Play Offline"), image: UIImage(systemName: "play.fill")) { _ in onPlayOffline() })
            }
            children.append(UIAction(title: String(localized: "Delete Download"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                manager.delete(key)
            })
            return UIMenu(title: item?.statusLine ?? "", children: children)
        }
    }

    static func spokenState(for ratingKey: String) -> String? {
        guard let item = DownloadManager.shared.item(for: ratingKey) else { return nil }
        switch item.state {
        case .queued: return String(localized: "download queued")
        case .waitingForWiFi: return String(localized: "download waiting for Wi-Fi")
        case .downloading: return String(localized: "downloading \(Int((item.progress * 100).rounded())) percent")
        case .paused: return String(localized: "download paused at \(Int((item.progress * 100).rounded())) percent")
        case .completed: return String(localized: "downloaded")
        case .failed: return String(localized: "download failed")
        }
    }
}
