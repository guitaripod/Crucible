import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

/// The cards web video draws: a video with its length in the corner and how far the viewer is in it, a playlist, and a
/// channel as its round picture.
@MainActor
enum WebCards {
    static let prefix = "web."

    /// The card of `entry`, with the viewer's progress in it from their library. `showsChannel` leaves the channel off
    /// the second line on a channel's own page; a shelf's card carries its views and age over the picture, a grid's
    /// (`inGrid`), which draws nothing there, on the second line. `upright` shows a Short's own upright picture.
    static func card(_ entry: WebEntry, showsChannel: Bool = true, inGrid: Bool = false, upright: Bool = false) -> CardItem {
        let watch = WebService.shared.library.watch(of: entry.id)
        let facts = WebFormatting.facts(entry)
        let second = inGrid ? (showsChannel ? WebFormatting.byline(entry) : facts) : (showsChannel ? entry.channel : facts)
        let artwork = upright ? WebArtwork.url(entry.shortThumbnailCandidates(sharp: false)).map(ArtworkSource.url) : WebArtwork.source(for: entry)
        var card = CardItem(id: prefix + entry.id, artwork: artwork, title: entry.title,
                            subtitle: second, detail: inGrid || !showsChannel ? nil : facts,
                            progress: watch.flatMap { $0.isFinished ? nil : $0.progress }, isWatched: watch?.isFinished ?? false,
                            placeholderSymbol: entry.kind == .channel ? "person.crop.circle" : "play.rectangle")
        switch entry.kind {
        case .video:
            if entry.isLive {
                card.badgeText = String(localized: "LIVE", comment: "Badge on a web video that is being broadcast now")
            } else if let duration = entry.duration, duration > 0 {
                card.badgeText = Formatters.timestamp(duration)
            }
        case .playlist:
            card.badgeText = String(localized: "Playlist", comment: "Badge on a card that opens a web playlist")
            card.primarySymbol = "list.bullet"
        case .channel:
            card.primarySymbol = "person.crop.circle"
        }
        card.canToggleWatched = false
        return card
    }

    /// The card of a Short on a shelf: upright, nine by sixteen, as wide as a poster, its title on two lines.
    static var shortStyle: CardStyle {
        var style = CardStyle.poster
        style.artworkSize = Size(width: style.itemWidth, height: (style.itemWidth * 16 / 9).rounded())
        style.titleLines = 2
        style.scrimsArtwork = true
        return style
    }

    /// A followed channel as a round card.
    static func card(_ channel: WebChannel) -> CardItem {
        var card = CardItem(id: prefix + "channel." + channel.id, artwork: WebArtwork.source(channel.avatar), title: channel.title, placeholderSymbol: "person.crop.circle")
        let gradient = CastAvatar.gradient(for: channel.title)
        card.monogram = CardItem.Monogram(initials: DetailFormat.initials(channel.title), top: Color(hex: gradient.start), bottom: Color(hex: gradient.end))
        card.canToggleWatched = false
        return card
    }
}
