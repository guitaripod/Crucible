import Foundation

/// Which Plex libraries become top-level tabs and which fall behind a More tab: only movie and
/// show libraries that count toward Home, in server order, with the first `limit - 1` kept as
/// tabs when there are more than `limit`.
package struct LibraryTabLayout: Sendable {
    package static let defaultLimit = 4

    package let tabs: [PlexDirectory]
    package let overflow: [PlexDirectory]

    package var hasMore: Bool { !overflow.isEmpty }

    package init(
        directories: [PlexDirectory],
        limit: Int = LibraryTabLayout.defaultLimit,
        isIncluded: (Int) -> Bool
    ) {
        let visible = directories.filter { directory in
            guard let type = directory.type, type == "movie" || type == "show",
                  let key = directory.key, let id = Int(key),
                  directory.title != nil
            else { return false }
            return isIncluded(id)
        }
        if visible.count > limit {
            tabs = Array(visible.prefix(limit - 1))
            overflow = Array(visible.dropFirst(limit - 1))
        } else {
            tabs = visible
            overflow = []
        }
    }

    package init(directories: [PlexDirectory], limit: Int = LibraryTabLayout.defaultLimit) {
        self.init(directories: directories, limit: limit, isIncluded: LibraryVisibility.isIncluded)
    }
}
