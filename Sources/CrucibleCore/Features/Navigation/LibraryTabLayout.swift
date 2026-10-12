import Foundation

/// Which Plex libraries become top-level tabs and which fall behind a More tab: every movie and
/// show library in server order, with the first `limit - 1` kept as tabs when there are more than
/// `limit`. Whether a library counts toward Home and Statistics (`LibraryVisibility`) plays no
/// part: a library Plex hides from Home is still a library to browse.
package struct LibraryTabLayout: Sendable {
    package static let defaultLimit = 4

    package let tabs: [PlexDirectory]
    package let overflow: [PlexDirectory]

    package var hasMore: Bool { !overflow.isEmpty }

    package init(directories: [PlexDirectory], limit: Int = LibraryTabLayout.defaultLimit) {
        let browsable = directories.filter { directory in
            guard let type = directory.type, type == "movie" || type == "show",
                  let key = directory.key, Int(key) != nil,
                  directory.title != nil
            else { return false }
            return true
        }
        if browsable.count > limit {
            tabs = Array(browsable.prefix(limit - 1))
            overflow = Array(browsable.dropFirst(limit - 1))
        } else {
            tabs = browsable
            overflow = []
        }
    }
}
