import CrucibleCore
import Foundation

/// The "Include in Statistics" choices, shared by every platform's library filter menu: one entry per
/// library with its on/off state, and the rule that the last included library cannot be switched off.
package struct StatsLibraryFilter: Equatable, Sendable {
    package struct Entry: Equatable, Sendable {
        package let id: Int
        package let title: String
        package let subtitle: String?
        package let symbol: String
        package let isIncluded: Bool
        package let isLocked: Bool
    }

    package let entries: [Entry]
    package let isCustomized: Bool
    package let hasOverrides: Bool

    package init(libraries: [LibraryVisibility.Library], isIncluded: (Int) -> Bool, isCustomized: Bool, hasOverrides: Bool) {
        let includedCount = libraries.filter { isIncluded($0.id) }.count
        entries = libraries.map { library in
            let isOn = isIncluded(library.id)
            return Entry(
                id: library.id,
                title: library.title,
                subtitle: library.hiddenOnPlex ? "Hidden from Home in Plex" : nil,
                symbol: library.symbol,
                isIncluded: isOn,
                isLocked: isOn && includedCount <= 1
            )
        }
        self.isCustomized = isCustomized
        self.hasOverrides = hasOverrides
    }

    /// The filter as the user has it set right now.
    package static func current() -> StatsLibraryFilter {
        StatsLibraryFilter(
            libraries: LibraryVisibility.libraries,
            isIncluded: LibraryVisibility.isIncluded,
            isCustomized: LibraryVisibility.isCustomized,
            hasOverrides: LibraryVisibility.hasOverrides
        )
    }

    /// A filter only makes sense with a choice to make.
    package var isAvailable: Bool { entries.count >= 2 }

    package var symbol: String {
        isCustomized ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
    }

    package var accessibilityValue: String {
        isCustomized ? "Filtered" : "All libraries"
    }

    @MainActor
    package func toggle(_ entry: Entry) {
        LibraryVisibility.setIncluded(entry.id, !entry.isIncluded)
    }

    @MainActor
    package func resetToPlexDefaults() {
        LibraryVisibility.resetToPlexDefaults()
    }
}
