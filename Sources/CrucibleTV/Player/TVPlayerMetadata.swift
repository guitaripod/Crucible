import AVFoundation
import CrucibleCore
import CrucibleDesign
import UIKit

/// The title, description, genres, rating and artwork the system player shows in its info panel.
enum TVPlayerMetadata {
    private static let artworkWidth = 600

    /// What the pre-roll and the info panel call the item before the server's full record arrives.
    static func headline(for display: PlaybackMetadata?) -> (title: String, subtitle: String?) {
        guard let display else { return ("", nil) }
        return (display.title, subtitle(display: display, detail: nil))
    }

    /// The episode line "Show · S2 · E5" or the movie's "2021 · PG-13".
    static func subtitle(display: PlaybackMetadata, detail: PlexMetadata?) -> String? {
        if let showName = display.showName {
            let code = Formatters.episodeCode(display.seasonNumber, display.episodeNumber)
            return [showName, code].compactMap { $0 }.joined(separator: " · ")
        }
        let parts = [detail?.year.map(String.init), detail?.contentRating]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    static func loadPoster(path: String) async -> UIImage? {
        await ImageLoader.shared.loadImage(path: path, width: artworkWidth)
    }

    static func loadArtwork(path: String?) async -> Data? {
        guard let path, let image = await loadPoster(path: path) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }

    static func items(display: PlaybackMetadata, detail: PlexMetadata?, artwork: Data?) -> [AVMetadataItem] {
        var items = [
            make(.commonIdentifierTitle, display.title),
            make(.commonIdentifierDescription, description(display: display, detail: detail)),
            make(.iTunesMetadataContentRating, detail?.contentRating),
            make(.quickTimeMetadataGenre, genres(detail)),
        ].compactMap { $0 }
        if let artwork {
            items.append(makeArtwork(artwork))
        }
        return items
    }

    /// The synopsis, led for an episode by its show and number: a subtitle item would replace the
    /// title in the info panel, so the show line travels with the description instead.
    private static func description(display: PlaybackMetadata, detail: PlexMetadata?) -> String? {
        let summary = detail?.summary.flatMap { $0.isEmpty ? nil : $0 }
        guard display.showName != nil, let line = subtitle(display: display, detail: detail) else { return summary }
        return [line, summary].compactMap { $0 }.joined(separator: "\n")
    }

    private static func genres(_ detail: PlexMetadata?) -> String? {
        let tags = detail?.Genre?.compactMap(\.tag) ?? []
        return tags.isEmpty ? nil : tags.prefix(3).joined(separator: ", ")
    }

    private static func make(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
        guard let value, !value.isEmpty else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private static func makeArtwork(_ data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        item.extendedLanguageTag = "und"
        return item
    }
}

extension TVPlaybackRequest {
    /// The engine's view of this request.
    var playbackRequest: PlaybackRequest {
        PlaybackRequest(
            ratingKey: ratingKey,
            mediaType: mediaType,
            showRatingKey: showRatingKey,
            seasonRatingKey: seasonRatingKey,
            resumePosition: resumeSeconds,
            metadata: display.map {
                PlaybackMetadata(
                    title: $0.title,
                    showName: $0.showName,
                    seasonNumber: $0.seasonNumber,
                    episodeNumber: $0.episodeNumber,
                    posterPath: $0.posterPath,
                    duration: $0.durationSeconds
                )
            },
            selectedSubtitleId: selectedSubtitleStreamID,
            selectedAudioStreamId: selectedAudioStreamID
        )
    }
}
