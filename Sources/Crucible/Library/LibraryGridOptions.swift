import UIKit

enum LibraryGridKind: Sendable {
    case movie, show

    var sortOptions: [LibrarySortOption] {
        switch self {
        case .movie:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: "Title"),
                LibrarySortOption(key: "year:desc", title: "Year"),
                LibrarySortOption(key: "addedAt:desc", title: "Recently Added"),
                LibrarySortOption(key: "rating:desc", title: "Rating"),
            ]
        case .show:
            return [
                LibrarySortOption(key: LibraryGridOptions.titleAscending, title: "Name"),
                LibrarySortOption(key: "addedAt:desc", title: "Recently Added"),
                LibrarySortOption(key: "rating:desc", title: "Rating"),
            ]
        }
    }

    var placeholderIcon: String {
        switch self {
        case .movie: return "film"
        case .show: return "tv"
        }
    }

    var emptyTitle: String {
        switch self {
        case .movie: return "No Movies"
        case .show: return "No Shows"
        }
    }

    var logName: String {
        switch self {
        case .movie: return "MovieGrid"
        case .show: return "ShowGrid"
        }
    }
}

struct LibrarySortOption: Equatable, Sendable {
    let key: String
    let title: String
}

enum LibraryWatchFilter: String, CaseIterable, Sendable {
    case all, unwatched, inProgress

    var title: String {
        switch self {
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .inProgress: return "In Progress"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        }
    }
}

/// The single source of truth for what a library grid shows; the chips row and the
/// navigation-bar options menu both read and write this value.
struct LibraryGridOptions: Equatable, Sendable {
    static let titleAscending = "titleSort:asc"

    var sort = titleAscending
    var genre: String?
    var watch: LibraryWatchFilter = .all

    var isFiltering: Bool { genre != nil || watch != .all }

    /// The A–Z index counts every item in the section, so it only lines up with the grid when the
    /// grid is the whole section sorted by title.
    var allowsAlphabetJump: Bool { sort == Self.titleAscending && !isFiltering }

    func endpoint(sectionId: String, start: Int, size: Int) -> PlexEndpoint {
        .sectionItems(
            sectionId: sectionId,
            sort: sort,
            genre: genre,
            start: start,
            size: size,
            unwatched: watch == .unwatched,
            inProgress: watch == .inProgress
        )
    }

    static func optionsImage(filtering: Bool) -> UIImage? {
        UIImage(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
    }
}

/// The trailing "grid size" control shared by the library host and stand-alone grids. The menu is
/// built lazily on every open so its checkmark always reflects the stored preference.
@MainActor
enum LibraryGridSizeMenu {
    static func barButtonItem(onChange: @escaping @MainActor @Sendable () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"), menu: menu(onChange: onChange))
        item.accessibilityLabel = "Grid Size"
        return item
    }

    static func menu(onChange: @escaping @MainActor @Sendable () -> Void) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { completion in
            let current = Preferences.libraryColumns
            completion([
                action(title: "Large (2 columns)", symbol: "square.grid.2x2", columns: 2, current: current, onChange: onChange),
                action(title: "Compact (3 columns)", symbol: "square.grid.3x3", columns: 3, current: current, onChange: onChange),
            ])
        }
        return UIMenu(title: "Grid Size", children: [deferred])
    }

    private static func action(
        title: String,
        symbol: String,
        columns: Int,
        current: Int,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), state: current == columns ? .on : .off) { _ in
            guard Preferences.libraryColumns != columns else { return }
            Preferences.libraryColumns = columns
            Haptics.selection()
            AppLogger.info("Library grid columns -> \(columns)", .ui)
            onChange()
        }
    }
}

struct LibraryFirstCharacterResponse: Decodable, Sendable {
    let MediaContainer: Container

    struct Container: Decodable, Sendable {
        let Directory: [Entry]?
    }

    struct Entry: Decodable, Sendable {
        let key: String?
        let title: String?
        let size: Int?
    }
}

/// Maps the section's `firstCharacter` counts onto item offsets in a title-ascending listing.
struct LibraryAlphabetIndex: Sendable {
    static let letters: [String] = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } } + ["#"]

    private var offsets: [String: Int] = [:]
    private var boundaries: [(offset: Int, letter: String)] = []

    init(entries: [LibraryFirstCharacterResponse.Entry]) {
        var running = 0
        for entry in entries {
            let count = max(entry.size ?? 0, 0)
            guard count > 0 else { continue }
            let letter = Self.normalized(entry.key ?? entry.title)
            if offsets[letter] == nil {
                offsets[letter] = running
                boundaries.append((running, letter))
            }
            running += count
        }
    }

    var isUsable: Bool { offsets.count >= 2 }

    /// The listing offset where `letter` starts, falling forward to the next letter that has items
    /// and back to the last one when nothing follows.
    func offset(for letter: String) -> Int? {
        if let exact = offsets[letter] { return exact }
        guard letter != "#", let start = Self.letters.firstIndex(of: letter) else { return nil }
        for candidate in Self.letters[start...] where candidate != "#" {
            if let offset = offsets[candidate] { return offset }
        }
        return boundaries.filter { $0.letter != "#" }.last?.offset
    }

    func letter(atOffset offset: Int) -> String? {
        boundaries.last { $0.offset <= offset }?.letter ?? boundaries.first?.letter
    }

    private static func normalized(_ raw: String?) -> String {
        guard let first = raw?.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        return letters.contains(folded) && folded != "#" ? folded : "#"
    }
}

enum LibraryFormat {
    static func timeLeft(_ item: PlexMetadata) -> String? {
        let remaining = item.durationSecs - item.positionSecs
        guard item.durationSecs > 0, remaining.isFinite, remaining > 0 else { return nil }
        let minutes = Int((remaining / 60).rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0 ? "\(hours) h \(rest) m left" : "\(hours) h left"
        }
        return minutes > 0 ? "\(minutes) min left" : "Less than a minute left"
    }

    static func continueTitle(_ item: PlexMetadata) -> String {
        if item.mediaType == "episode", let show = item.grandparentTitle {
            return show
        }
        return item.title
    }

    static func continueDetail(_ item: PlexMetadata) -> String {
        var parts = [continueTitle(item)]
        if item.mediaType == "episode", let code = Formatters.episodeCode(item.parentIndex, item.index) {
            parts.append(code)
        }
        if let left = timeLeft(item) { parts.append(left) }
        return parts.joined(separator: " · ")
    }
}
