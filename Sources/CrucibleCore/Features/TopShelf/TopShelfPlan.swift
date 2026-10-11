import Foundation

/// What the Top Shelf extension shows, in plain values: one row of sections, each tile with its
/// artwork, progress and the two URLs it opens. `nil` means "nothing to show", so the system
/// falls back to the static branded image.
package struct TopShelfPlan: Equatable, Sendable {
    package struct Item: Equatable, Sendable {
        package let identifier: String
        package let title: String
        package let imageURL: URL?
        package let progress: Double?
        package let playURL: URL?
        package let displayURL: URL
    }

    package struct Section: Equatable, Sendable {
        package let title: String
        package let items: [Item]
    }

    package let sections: [Section]

    package init?(snapshot: TopShelfSnapshot?) {
        guard let snapshot, snapshot.schema == TopShelfSnapshot.schemaVersion else { return nil }
        let sections = snapshot.sections
            .map { section in Section(title: section.title, items: section.items.map(Self.item(from:))) }
            .filter { !$0.items.isEmpty }
        guard !sections.isEmpty else { return nil }
        self.sections = sections
    }

    private static func item(from item: TopShelfItem) -> Item {
        Item(
            identifier: item.ratingKey,
            title: item.title,
            imageURL: item.imageURL,
            progress: item.progress,
            playURL: isPlayable(type: item.type) ? DeepLink.play(ratingKey: item.ratingKey).url : nil,
            displayURL: DeepLink.item(ratingKey: item.ratingKey, mediaType: DeepLink.isItemType(item.type) ? item.type : nil).url
        )
    }

    private static func isPlayable(type: String) -> Bool {
        type == "movie" || type == "episode" || type == "clip"
    }
}
