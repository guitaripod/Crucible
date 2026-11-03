import AVFoundation
import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import UIKit

extension TVPlayerCoordinator {
    /// The title's chapters in the player's own chapter list, named and, once their thumbnails load, with a picture each.
    /// Times are on the item's timeline, so a stream that starts at an offset leaves out the chapters before it.
    func applyChapters(to item: AVPlayerItem) {
        guard let session, let chapters = session.stream?.chapters, !chapters.isEmpty else { return }
        let offset = session.streamOffset
        item.navigationMarkerGroups = Self.markerGroups(chapters, offset: offset, artwork: [:])
        Task { [weak item] in
            var artwork = [String: Data]()
            for chapter in chapters {
                guard let thumb = chapter.thumb, let image = await ImageLoader.shared.loadImage(path: thumb, width: 480),
                      let data = image.jpegData(compressionQuality: 0.8) else { continue }
                artwork[thumb] = data
            }
            guard !artwork.isEmpty, let item else { return }
            item.navigationMarkerGroups = Self.markerGroups(chapters, offset: offset, artwork: artwork)
        }
    }

    private static func markerGroups(_ chapters: [PlexChapter], offset: Double, artwork: [String: Data]) -> [AVNavigationMarkersGroup] {
        let markers = chapters.compactMap { chapter -> AVTimedMetadataGroup? in
            let start = chapter.startSecs - offset
            guard start >= 0 else { return nil }
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
            let duration = max(1, chapter.endSecs - chapter.startSecs)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
            return AVTimedMetadataGroup(items: items, timeRange: range)
        }
        guard markers.count > 1 else { return [] }
        return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
    }
}
