import Foundation

/// One tile on the Apple TV Top Shelf.
package struct TopShelfItem: Codable, Equatable, Sendable {
    package let ratingKey: String
    package let type: String
    package let title: String
    package let subtitle: String?
    package let imageURL: URL?
    package let progress: Double?

    package init(ratingKey: String, type: String, title: String, subtitle: String?, imageURL: URL?, progress: Double?) {
        self.ratingKey = ratingKey
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.progress = progress
    }
}

package struct TopShelfSection: Codable, Equatable, Sendable {
    package let title: String
    package let items: [TopShelfItem]

    package init(title: String, items: [TopShelfItem]) {
        self.title = title
        self.items = items
    }
}

/// The tiny JSON file the app leaves in the App Group container for the Top Shelf extension, which
/// does no networking of its own. At most `TopShelfBuilder.maxItemsPerSection` items per section.
package struct TopShelfSnapshot: Codable, Equatable, Sendable {
    package static let schemaVersion = 1

    package let schema: Int
    package let machineIdentifier: String
    package let savedAt: Int
    package let sections: [TopShelfSection]

    package init(schema: Int = TopShelfSnapshot.schemaVersion, machineIdentifier: String, savedAt: Int, sections: [TopShelfSection]) {
        self.schema = schema
        self.machineIdentifier = machineIdentifier
        self.savedAt = savedAt
        self.sections = sections
    }

    package var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }

    /// Equal apart from the save time, so an unchanged Top Shelf is not rewritten or re-announced.
    package func hasSameContent(as other: TopShelfSnapshot) -> Bool {
        schema == other.schema && machineIdentifier == other.machineIdentifier && sections == other.sections
    }
}
