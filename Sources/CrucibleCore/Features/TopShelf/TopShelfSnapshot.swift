import Foundation

/// One tile on the Apple TV Top Shelf.
package struct TopShelfItem: Codable, Equatable, Sendable {
    package let ratingKey: String
    package let type: String
    package let title: String
    package let subtitle: String?
    package let summary: String?
    package let imageURL: URL?
    package let image2xURL: URL?
    package let progress: Double?

    package init(
        ratingKey: String,
        type: String,
        title: String,
        subtitle: String?,
        summary: String? = nil,
        imageURL: URL?,
        image2xURL: URL? = nil,
        progress: Double?
    ) {
        self.ratingKey = ratingKey
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.imageURL = imageURL
        self.image2xURL = image2xURL
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
    package static let schemaVersion = 2

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

    package var itemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    /// Equal apart from the save time, so an unchanged Top Shelf is not rewritten or re-announced.
    package func hasSameContent(as other: TopShelfSnapshot) -> Bool {
        schema == other.schema && machineIdentifier == other.machineIdentifier && sections == other.sections
    }
}

/// What the extension saw the last time tvOS asked it for content. The app shows it in Diagnostics,
/// because the extension's own process has no other way to report back.
package struct TopShelfReceipt: Codable, Equatable, Sendable {
    package static let schemaVersion = 1

    package let schema: Int
    package let readAt: Int
    package let itemCount: Int
    package let imageCount: Int
    package let snapshotSchema: Int?

    package init(
        readAt: Int = Int(Date().timeIntervalSince1970),
        itemCount: Int,
        imageCount: Int,
        snapshotSchema: Int?
    ) {
        self.schema = Self.schemaVersion
        self.readAt = readAt
        self.itemCount = itemCount
        self.imageCount = imageCount
        self.snapshotSchema = snapshotSchema
    }

    package var date: Date {
        Date(timeIntervalSince1970: TimeInterval(readAt))
    }
}
