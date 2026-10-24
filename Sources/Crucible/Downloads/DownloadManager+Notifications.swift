import CrucibleCore
import Foundation
import UserNotifications

extension DownloadManager {
    func notifyDownloadComplete(_ item: DownloadItem) {
        var parts: [String] = []
        if let subtitle = item.episodeSubtitle { parts.append(subtitle) }
        parts.append(item.quality.shortLabel)
        if item.totalBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
        }
        postDownloadNotification(
            title: item.displayTitle,
            subtitle: "Download complete",
            body: parts.joined(separator: " · "),
            ratingKey: item.ratingKey,
            mediaType: item.mediaType
        )
    }

    /// The Live Activity ends immediately when the last item fails, indistinguishable from success at
    /// a glance — a failure notification is the only lock-screen signal the download did not finish.
    func notifyDownloadFailed(_ item: DownloadItem, message: String) {
        var parts: [String] = []
        if let subtitle = item.episodeSubtitle { parts.append(subtitle) }
        parts.append(message)
        postDownloadNotification(
            title: item.displayTitle,
            subtitle: "Download failed",
            body: parts.joined(separator: " · "),
            ratingKey: item.ratingKey,
            mediaType: item.mediaType
        )
    }

    private func postDownloadNotification(title: String, subtitle: String, body: String, ratingKey: String, mediaType: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = "crucible.downloads"
        content.userInfo = ["ratingKey": ratingKey, "mediaType": mediaType]
        if let attachment = posterAttachment(ratingKey: ratingKey) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: "crucible.download.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Attachments are moved into the notification store, so the poster is copied to a temp file
    /// first — attaching the original would delete the artwork the Downloads UI still displays.
    private func posterAttachment(ratingKey: String) -> UNNotificationAttachment? {
        let poster = DownloadPaths.posterURL(ratingKey: ratingKey)
        guard FileManager.default.fileExists(atPath: poster.path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-poster-\(ratingKey)-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: poster, to: tmp)
            return try UNNotificationAttachment(identifier: "poster", url: tmp)
        } catch {
            return nil
        }
    }
}
