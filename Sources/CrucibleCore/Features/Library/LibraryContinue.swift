import Foundation

package struct ContinueBannerModel: Equatable, Sendable {
    package let itemId: String
    package let detail: String
    package let artPath: String?
    package let spokenLabel: String

    package init(itemId: String, detail: String, artPath: String?, spokenLabel: String) {
        self.itemId = itemId
        self.detail = detail
        self.artPath = artPath
        self.spokenLabel = spokenLabel
    }

    package init(item: PlexMetadata) {
        let detail = LibraryFormat.continueDetail(item)
        self.init(
            itemId: item.id,
            detail: detail,
            artPath: item.art ?? item.grandparentArt ?? item.thumb,
            spokenLabel: "Continue \(detail)"
        )
    }
}

/// Which part-watched item a library offers as "Continue", read from the section's hubs.
package enum LibraryContinue {
    /// The first part-watched item of any hub whose identifier names continue, in-progress or
    /// on-deck content; whole shows never qualify.
    package static func select(from hubs: [PlexHub]) -> PlexMetadata? {
        hubs
            .filter { hub in
                let id = (hub.hubIdentifier ?? "").lowercased()
                return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
            }
            .flatMap { $0.Metadata ?? [] }
            .first { $0.mediaType != "show" && $0.resumeSecs > 0 }
    }

    /// Whether `item` is already what the Continue banner offers; a show library's cards stand for
    /// the series, so they match on the series.
    package static func isFeatured(_ item: PlexMetadata, by continueItem: PlexMetadata?, kind: LibraryGridKind) -> Bool {
        guard let continueItem else { return false }
        switch kind {
        case .movie:
            return item.id == continueItem.id
        case .show:
            return (item.grandparentRatingKey ?? item.id) == (continueItem.grandparentRatingKey ?? continueItem.id)
        }
    }

    /// Whether a freshly selected item differs from the one on show enough to redraw the banner.
    package static func differs(_ next: PlexMetadata?, from current: PlexMetadata?) -> Bool {
        next?.id != current?.id || next?.viewOffset != current?.viewOffset
    }
}
