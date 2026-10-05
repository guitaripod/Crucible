import Foundation

/// Which libraries count toward Home and Statistics. Plex's own "hide from Home" flag sets the
/// default for each library; an explicit choice overrides it either way. Reads are safe from any
/// thread so the statistics queries can consult the current choice; changes are made on the main
/// actor and announced to observers.
enum LibraryVisibility {
    struct Library: Codable, Hashable, Sendable {
        let id: Int
        let title: String
        let type: String
        let hiddenOnPlex: Bool

        var symbol: String {
            switch type {
            case "movie": return "film"
            case "show": return "tv"
            case "artist": return "music.note"
            case "photo": return "photo"
            default: return "rectangle.stack"
            }
        }
    }

    private static let librariesKey = "knownLibraries"
    private static let overridesKey = "libraryOverrides"

    @MainActor private static var observers = [UUID: @MainActor () -> Void]()

    static var libraries: [Library] {
        guard let data = UserDefaults.standard.data(forKey: librariesKey) else { return [] }
        return (try? JSONDecoder().decode([Library].self, from: data)) ?? []
    }

    private static var overrides: [Int: Bool] {
        let stored = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static var hasOverrides: Bool { !overrides.isEmpty }

    static func isIncluded(_ id: Int) -> Bool {
        if let choice = overrides[id] { return choice }
        return !(libraries.first { $0.id == id }?.hiddenOnPlex ?? false)
    }

    /// Library ids to leave out of Home and Statistics.
    static var excluded: Set<Int> {
        let choices = overrides
        var result = Set(choices.filter { !$0.value }.keys)
        for library in libraries where library.hiddenOnPlex && choices[library.id] == nil {
            result.insert(library.id)
        }
        return result
    }

    static var isCustomized: Bool { !excluded.isEmpty }

    /// Remembers the server's library list and its hide-from-Home flags.
    @MainActor
    static func record(directories: [PlexDirectory]) {
        let fresh = directories.compactMap { directory -> Library? in
            guard let key = directory.key, let id = Int(key), let title = directory.title else { return nil }
            return Library(id: id, title: title, type: directory.type ?? "", hiddenOnPlex: directory.isHiddenFromHome)
        }
        guard !fresh.isEmpty, fresh != libraries, let data = try? JSONEncoder().encode(fresh) else { return }
        UserDefaults.standard.set(data, forKey: librariesKey)
        notify()
    }

    /// Returns false, and changes nothing, when it would leave no library included.
    @MainActor
    @discardableResult
    static func setIncluded(_ id: Int, _ included: Bool) -> Bool {
        if !included, isIncluded(id), libraries.filter({ isIncluded($0.id) }).count <= 1 { return false }
        var choices = overrides
        let plexDefault = !(libraries.first { $0.id == id }?.hiddenOnPlex ?? false)
        if included == plexDefault {
            choices[id] = nil
        } else {
            choices[id] = included
        }
        store(choices)
        notify()
        return true
    }

    @MainActor
    static func resetToPlexDefaults() {
        store([:])
        notify()
    }

    @MainActor
    static func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    @MainActor
    static func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private static func store(_ choices: [Int: Bool]) {
        let stored = Dictionary(uniqueKeysWithValues: choices.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(stored, forKey: overridesKey)
    }

    @MainActor
    private static func notify() {
        observers.values.forEach { $0() }
    }
}
