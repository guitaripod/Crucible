import Foundation

/// A movie or show library of the server, in the order the server lists them. Libraries of other
/// types are not browsable and never appear. This list does not apply `LibraryVisibility`: the
/// Library screens show every browsable library, as the iPhone always has.
package struct LibrarySection: Equatable, Sendable {
    package let id: String
    package let title: String
    package let kind: LibraryGridKind

    package init(id: String, title: String, kind: LibraryGridKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    package static func sections(in container: PlexMediaContainer) -> [LibrarySection] {
        (container.Directory ?? []).compactMap { directory in
            guard let key = directory.key, let kind = LibraryGridKind(sectionType: directory.type) else { return nil }
            return LibrarySection(id: key, title: directory.title ?? kind.defaultTitle, kind: kind)
        }
    }

    package static func load(api: APIClient) async throws -> [LibrarySection] {
        sections(in: try await api.requestContainer(.sections))
    }
}
