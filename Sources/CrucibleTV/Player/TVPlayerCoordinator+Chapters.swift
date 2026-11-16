import AVFoundation
import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import UIKit

extension TVPlayerCoordinator {
    /// The title's chapters in the player's own chapter list, named and, once their thumbnails load, with a picture each.
    /// Times are on the player's clock, so a stream whose clock starts at an offset leaves out the chapters that end before it
    /// and starts the one it begins inside at zero. The pictures load together and are kept for the next item, so a restarted
    /// stream shows them at once; a newer call replaces an older one still loading, whose offset may no longer be right.
    func applyChapters(to item: AVPlayerItem) {
        chapterTask?.cancel()
        chapterTask = nil
        guard let session, let chapters = session.stream?.chapters, !chapters.isEmpty else { return }
        let offset = session.streamOffset
        item.navigationMarkerGroups = Self.markerGroups(chapters, offset: offset, artwork: chapterArtwork)
        let missing = Set(chapters.compactMap(\.thumb)).subtracting(chapterArtwork.keys)
        guard !missing.isEmpty else { return }
        chapterTask = Task { [weak self, weak item] in
            let loaded = await Self.loadArtwork(missing)
            guard !Task.isCancelled, let self, !loaded.isEmpty else { return }
            chapterArtwork.merge(loaded) { _, new in new }
            guard let item else { return }
            item.navigationMarkerGroups = Self.markerGroups(chapters, offset: offset, artwork: chapterArtwork)
        }
    }

    private static func loadArtwork(_ thumbs: Set<String>) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            for thumb in thumbs {
                group.addTask {
                    let image = await ImageLoader.shared.loadImage(path: thumb, width: 480)
                    return (thumb, image?.jpegData(compressionQuality: 0.8))
                }
            }
            var artwork = [String: Data]()
            for await (thumb, data) in group {
                if let data { artwork[thumb] = data }
            }
            return artwork
        }
    }

    private static func markerGroups(_ chapters: [PlexChapter], offset: Double, artwork: [String: Data]) -> [AVNavigationMarkersGroup] {
        let markers = chapters.compactMap { chapter -> AVTimedMetadataGroup? in
            let end = chapter.endSecs - offset
            guard end > 1 else { return nil }
            let start = max(0, chapter.startSecs - offset)
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = chapter.title as NSString
            title.extendedLanguageTag = "und"
            var items: [AVMetadataItem] = [title]
            if let thumb = chapter.thumb, let data = artwork[thumb] {
                let image = AVMutableMetadataItem()
                image.identifier = .commonIdentifierArtwork
                image.value = data as NSData
                image.dataType = kCMMetadataBaseDataType_JPEG as String
                image.extendedLanguageTag = "und"
                items.append(image)
            }
            let duration = max(1, end - start)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
            return AVTimedMetadataGroup(items: items, timeRange: range)
        }
        guard markers.count > 1 else { return [] }
        return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
    }
}
