import Foundation

/// The rows and copy of the Libraries screen over `LibraryVisibility`. Switching a library goes
/// through `LibraryVisibility.setIncluded` (it returns false for the last included library) and
/// "Reset to Plex Defaults" through `LibraryVisibility.resetToPlexDefaults`; observe changes with
/// `LibraryVisibility.addObserver`.
package enum LibrariesSettings {
    package struct Row: Hashable, Sendable {
        package let id: Int
        package let symbol: String
        package let title: String
        package let subtitle: String?
        package let isIncluded: Bool
        package let isLocked: Bool
    }

    package static let footerText = "Libraries Plex hides from Home start switched off. At least one library stays on."
    package static let homeFooterText = "Choose which libraries appear on Home and count toward your statistics."
    package static let resetTitle = "Reset to Plex Defaults"
    package static let loadingTitle = "Loading Libraries"

    package static var libraryIDs: [Int] {
        LibraryVisibility.libraries.map(\.id)
    }

    package static var isLoading: Bool {
        LibraryVisibility.libraries.isEmpty
    }

    package static var canReset: Bool {
        LibraryVisibility.hasOverrides
    }

    package static var rows: [Row] {
        rows(for: LibraryVisibility.libraries, isIncluded: LibraryVisibility.isIncluded)
    }

    package static func row(id: Int) -> Row? {
        rows.first { $0.id == id }
    }

    /// "All" when every library counts, "2 of 3" otherwise, nil before the server's list is known.
    package static var summary: String? {
        summary(for: LibraryVisibility.libraries, isIncluded: LibraryVisibility.isIncluded)
    }

    /// Fetches the server's library list and records it; a failed or cancelled request changes nothing.
    @MainActor
    package static func refresh(api: APIClient) async {
        guard let container = try? await api.requestContainer(.sections), !Task.isCancelled else { return }
        LibraryVisibility.record(directories: container.Directory ?? [])
    }

    static func rows(for libraries: [LibraryVisibility.Library], isIncluded: (Int) -> Bool) -> [Row] {
        let includedCount = libraries.filter { isIncluded($0.id) }.count
        return libraries.map { library in
            let included = isIncluded(library.id)
            return Row(
                id: library.id,
                symbol: library.symbol,
                title: library.title,
                subtitle: library.hiddenOnPlex ? "Hidden from Home in Plex" : nil,
                isIncluded: included,
                isLocked: included && includedCount <= 1
            )
        }
    }

    static func summary(for libraries: [LibraryVisibility.Library], isIncluded: (Int) -> Bool) -> String? {
        guard !libraries.isEmpty else { return nil }
        let included = libraries.filter { isIncluded($0.id) }.count
        return included == libraries.count ? "All" : "\(included) of \(libraries.count)"
    }
}
