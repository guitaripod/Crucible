import Foundation

/// What the Top Shelf extension shows, in plain values: one row of carousel cards, each with its
/// artwork, context line, details, preview video and the two URLs it opens. `nil` means "nothing to show", so the
/// system falls back to the static branded image.
package struct TopShelfPlan: Equatable, Sendable {
    package static let maxItems = TopShelfBuilder.maxItems

    package struct Item: Equatable, Sendable {
        package let identifier: String
        package let title: String
        package let contextTitle: String?
        package let summary: String?
        package let genre: String?
        package let duration: TimeInterval?
        package let creationDate: Date?
        package let mediaOptions: [TopShelfMediaOption]
        package let attributes: [TopShelfAttribute]
        package let imageURL: URL?
        package let image2xURL: URL?
        package let previewURL: URL?
        package let playURL: URL?
        package let displayURL: URL
    }

    package let items: [Item]

    /// Nil when there is nothing to show: no snapshot, a schema it cannot read, no items, or a Pro Week's snapshot past its end.
    package init?(snapshot: TopShelfSnapshot?, now: Date = Date(), calendar: Calendar = .current) {
        guard let snapshot, TopShelfSnapshot.readableSchemas.contains(snapshot.schema), snapshot.isAvailable(at: now) else { return nil }
        let items = snapshot.sections
            .flatMap(\.items)
            .prefix(Self.maxItems)
            .map { Self.item(from: $0, calendar: calendar) }
        guard !items.isEmpty else { return nil }
        self.items = Array(items)
    }

    /// The release date at noon in the viewer's time zone, so the year the carousel prints is the one the server wrote
    /// even for a title released on the 1st of January.
    package static func creationDate(_ text: String?, calendar: Calendar) -> Date? {
        guard let parts = text?.prefix(10).split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func item(from item: TopShelfItem, calendar: Calendar) -> Item {
        Item(
            identifier: item.ratingKey,
            title: item.title,
            contextTitle: item.subtitle,
            summary: item.summary,
            genre: item.genre,
            duration: item.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            creationDate: creationDate(item.releaseDate, calendar: calendar),
            mediaOptions: item.mediaOptions ?? [],
            attributes: item.attributes ?? [],
            imageURL: item.imageURL,
            image2xURL: item.image2xURL,
            previewURL: item.previewURL,
            playURL: DeepLink.isPlayableType(item.type) ? DeepLink.play(ratingKey: item.ratingKey).url : nil,
            displayURL: DeepLink.item(ratingKey: item.ratingKey, mediaType: DeepLink.isItemType(item.type) ? item.type : nil).url
        )
    }
}
