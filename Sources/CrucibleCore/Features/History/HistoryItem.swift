import Foundation

package struct HistoryItem: Hashable, Sendable {
    package let ratingKey: String
    package let title: String
    package let type: String?
    package let viewedAt: Int?
    package let thumb: String?
    package let grandparentThumb: String?
    package let grandparentTitle: String?
    package let grandparentRatingKey: String?
    package let parentRatingKey: String?
    package let parentIndex: Int?
    package let index: Int?
    package let duration: Int?
    package let uniqueId: String

    package init(
        ratingKey: String,
        title: String,
        type: String?,
        viewedAt: Int?,
        thumb: String?,
        grandparentThumb: String?,
        grandparentTitle: String?,
        grandparentRatingKey: String?,
        parentRatingKey: String?,
        parentIndex: Int?,
        index: Int?,
        duration: Int?,
        uniqueId: String
    ) {
        self.ratingKey = ratingKey
        self.title = title
        self.type = type
        self.viewedAt = viewedAt
        self.thumb = thumb
        self.grandparentThumb = grandparentThumb
        self.grandparentTitle = grandparentTitle
        self.grandparentRatingKey = grandparentRatingKey
        self.parentRatingKey = parentRatingKey
        self.parentIndex = parentIndex
        self.index = index
        self.duration = duration
        self.uniqueId = uniqueId
    }
}

extension HistoryItem {
    /// Lifts one history row into an item. `position` is the row's absolute index in the server's list,
    /// which makes `uniqueId` offset-based: a refresh or a new play shifts it.
    package init(metadata m: PlexMetadata, position: Int) {
        self.init(
            ratingKey: m.id,
            title: m.title,
            type: m.type,
            viewedAt: m.viewedAt ?? m.lastViewedAt ?? m.addedAt,
            thumb: m.thumb,
            grandparentThumb: m.grandparentThumb,
            grandparentTitle: m.grandparentTitle,
            grandparentRatingKey: m.grandparentRatingKey,
            parentRatingKey: m.parentRatingKey,
            parentIndex: m.parentIndex,
            index: m.index,
            duration: m.duration,
            uniqueId: "\(m.id)-\(position)"
        )
    }

    /// Maps one page of the history endpoint, which started at `offset`, into items in server order.
    package static func items(in container: PlexMediaContainer, offset: Int) -> [HistoryItem] {
        (container.Metadata ?? []).enumerated().map { index, metadata in
            HistoryItem(metadata: metadata, position: offset + index)
        }
    }
}
