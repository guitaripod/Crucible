import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

extension SearchHighlight {
    /// Marks the part of `text` that the query matched: the whole query when it occurs, otherwise each
    /// query word that does. Matching ignores case and diacritics.
    static func attributed(
        _ text: String,
        query: String?,
        font: UIFont,
        color: UIColor,
        highlightColor: UIColor = Theme.Color.accentText
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard let query, !query.isEmpty else { return result }
        for range in matchRanges(of: query, in: text) {
            result.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }
        return result
    }
}

extension PosterContentConfiguration {
    /// Poster-with-caption configuration for any library item. Seasons and episodes are shown as the
    /// show they belong to, since that is what the user recognises.
    @MainActor static func search(_ item: PlexMetadata) -> PosterContentConfiguration {
        let model = SearchPosterModel(item: item)
        var config = PosterContentConfiguration()
        config.isDownloaded = DownloadManager.shared.item(for: item.id)?.state == .completed
        config.posterPath = model.posterPath
        config.title = model.title
        config.subtitle = model.subtitle
        config.placeholderIcon = model.placeholderIcon
        config.unwatchedCount = model.unwatchedCount
        config.progress = model.progress
        config.isUnwatched = model.isUnwatched
        return config
    }
}
