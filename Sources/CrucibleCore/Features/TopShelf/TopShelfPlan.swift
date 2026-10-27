import Foundation

/// What the Top Shelf extension shows, in plain values: one row of carousel cards, each with its
/// artwork, context line, summary and the two URLs it opens. `nil` means "nothing to show", so the
/// system falls back to the static branded image.
package struct TopShelfPlan: Equatable, Sendable {
    /// A carousel stays useful up to about ten cards; the rest of the Home buckets would only add
    /// scroll distance the system never shows.
    package static let maxItems = 10

    package struct Item: Equatable, Sendable {
        package let identifier: String
        package let title: String
        package let contextTitle: String?
        package let summary: String?
        package let imageURL: URL?
        package let image2xURL: URL?
        package let playURL: URL?
        package let displayURL: URL
    }

    package let items: [Item]

    package init?(snapshot: TopShelfSnapshot?) {
        guard let snapshot, snapshot.schema == TopShelfSnapshot.schemaVersion else { return nil }
        let items = snapshot.sections
            .flatMap(\.items)
            .prefix(Self.maxItems)
            .map(Self.item(from:))
        guard !items.isEmpty else { return nil }
        self.items = Array(items)
    }

    private static func item(from item: TopShelfItem) -> Item {
        Item(
            identifier: item.ratingKey,
            title: item.title,
            contextTitle: item.subtitle,
            summary: item.summary,
            imageURL: item.imageURL,
            image2xURL: item.image2xURL,
            playURL: DeepLink.isPlayableType(item.type) ? DeepLink.play(ratingKey: item.ratingKey).url : nil,
            displayURL: DeepLink.item(ratingKey: item.ratingKey, mediaType: DeepLink.isItemType(item.type) ? item.type : nil).url
        )
    }
}
