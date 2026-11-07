import Foundation

/// One card of the Apple TV Top Shelf carousel.
package struct TopShelfItem: Codable, Equatable, Sendable {
    package let ratingKey: String
    package let type: String
    /// The show for an episode, the title otherwise.
    package let title: String
    /// Why the card is there: "Continue Watching · 17 min left", "New Episode", "Recently Added".
    package let subtitle: String?
    package let summary: String?
    package let imageURL: URL?
    package let image2xURL: URL?
    package let progress: Double?
    package let genre: String?
    /// The runtime in seconds.
    package let duration: Double?
    /// The release or air date as the server writes it, "2024-03-08".
    package let releaseDate: String?
    package let mediaOptions: [TopShelfMediaOption]?
    package let attributes: [TopShelfAttribute]?
    /// What plays once focus rests on the card: the scene where the viewer stopped, or the title's trailer.
    package let previewURL: URL?
    /// The transcoder session `previewURL` starts, so the app can end it when the viewer goes from the card into the app.
    package let previewSession: String?

    package init(
        ratingKey: String,
        type: String,
        title: String,
        subtitle: String?,
        summary: String? = nil,
        imageURL: URL?,
        image2xURL: URL? = nil,
        progress: Double?,
        genre: String? = nil,
        duration: Double? = nil,
        releaseDate: String? = nil,
        mediaOptions: [TopShelfMediaOption]? = nil,
        attributes: [TopShelfAttribute]? = nil,
        previewURL: URL? = nil,
        previewSession: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.imageURL = imageURL
        self.image2xURL = image2xURL
        self.progress = progress
        self.genre = genre
        self.duration = duration
        self.releaseDate = releaseDate
        self.mediaOptions = mediaOptions
        self.attributes = attributes
        self.previewURL = previewURL
        self.previewSession = previewSession
    }
}

/// A capability badge the carousel draws under a card's summary; at most one resolution and one dynamic range.
package enum TopShelfMediaOption: String, Codable, Sendable, CaseIterable {
    case hd
    case uhd
    case hdr
    case dolbyVision
    case atmos
    case closedCaptions
    case sdh
    case audioDescription
}

/// A named list the carousel sets beside a card's details, such as Starring and the actors.
package struct TopShelfAttribute: Codable, Equatable, Sendable {
    package let name: String
    package let values: [String]

    package init(name: String, values: [String]) {
        self.name = name
        self.values = values
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
/// does no networking of its own. At most `TopShelfBuilder.maxItems` items in all.
package struct TopShelfSnapshot: Codable, Equatable, Sendable {
    package static let schemaVersion = 3
    /// The schemas the extension can still show: an update keeps the last version's cards on the Top Shelf until the app
    /// next opens and writes the new schema, instead of falling back to the static image.
    package static let readableSchemas = 2...schemaVersion

    package let schema: Int
    package let machineIdentifier: String
    package let savedAt: Int
    package let sections: [TopShelfSection]
    /// When the content stops being shown, in seconds since 1970: the end of the Pro Week that published it. Nil for Pro, whose
    /// Top Shelf has no end. The extension checks it, so an ended week empties the Top Shelf even before the app opens again.
    package let availableUntil: Int?

    package init(
        schema: Int = TopShelfSnapshot.schemaVersion,
        machineIdentifier: String,
        savedAt: Int,
        sections: [TopShelfSection],
        availableUntil: Int? = nil
    ) {
        self.schema = schema
        self.machineIdentifier = machineIdentifier
        self.savedAt = savedAt
        self.sections = sections
        self.availableUntil = availableUntil
    }

    /// The same content, shown until `end`, or without an end for nil.
    package func available(until end: Date?) -> TopShelfSnapshot {
        TopShelfSnapshot(
            schema: schema, machineIdentifier: machineIdentifier, savedAt: savedAt, sections: sections,
            availableUntil: end.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        )
    }

    package func isAvailable(at now: Date) -> Bool {
        guard let availableUntil else { return true }
        return now.timeIntervalSince1970 < Double(availableUntil)
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
            && availableUntil == other.availableUntil
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
    /// Cards with a preview video; nil in a receipt an earlier version wrote.
    package let previewCount: Int?
    package let snapshotSchema: Int?

    package init(
        readAt: Int = Int(Date().timeIntervalSince1970),
        itemCount: Int,
        imageCount: Int,
        previewCount: Int? = nil,
        snapshotSchema: Int?
    ) {
        self.schema = Self.schemaVersion
        self.readAt = readAt
        self.itemCount = itemCount
        self.imageCount = imageCount
        self.previewCount = previewCount
        self.snapshotSchema = snapshotSchema
    }

    package var date: Date {
        Date(timeIntervalSince1970: TimeInterval(readAt))
    }
}
