import Foundation

/// One level of a library's folder tree: the sub-folders and the playable media directly inside.
package struct LibraryFolderListing: Sendable {
    package struct Folder: Hashable, Sendable {
        package let key: String
        package let title: String
    }

    package enum Source: Sendable {
        case section(String)
        case folder(String)

        var endpoint: PlexEndpoint {
            switch self {
            case .section(let sectionId): return .sectionFolder(sectionId: sectionId)
            case .folder(let path): return .folderPath(path)
            }
        }
    }

    package let folders: [Folder]
    package let media: [PlexMetadata]

    package var isEmpty: Bool { folders.isEmpty && media.isEmpty }

    package init(container: PlexMediaContainer) {
        var folders = [Folder]()
        var media = [PlexMetadata]()
        for directory in container.Directory ?? [] {
            guard let key = directory.key else { continue }
            folders.append(Folder(key: key, title: directory.title ?? key.components(separatedBy: "/").last ?? key))
        }
        for item in container.Metadata ?? [] {
            if item.ratingKey != nil {
                media.append(item)
            } else if let key = item.key {
                folders.append(Folder(key: key, title: item.title))
            }
        }
        self.folders = folders
        self.media = media
    }

    package static func load(_ source: Source, api: APIClient) async throws -> LibraryFolderListing {
        LibraryFolderListing(container: try await api.requestContainer(source.endpoint))
    }
}
