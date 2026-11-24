import Foundation

/// The titles this app cannot play here, kept on the Plex server itself as a label so every device of the same server
/// agrees on what to leave out. A mark is written when the server's conversion has no picture in it, when a title fails
/// to play after the transcoder has had its turn, or when the viewer says so; the label then makes the title disappear
/// from Home, search, notifications and the library grids on every device, and this device's copy answers before the
/// server is asked.
///
/// Section ids and rating keys belong to one server, so the marks are kept per server and forgotten when another one is
/// connected. Reads are safe from any thread; changes are made on the main actor and announced through
/// `.crucibleIncompatibleTitlesChanged`.
package enum IncompatibleTitles {
    /// The label the server keeps, in its own words, so Plex Web and Plex's own clients read it too.
    package static let label = "Crucible Incompatible"

    package static let changed = Notification.Name("crucible.incompatibleTitlesChanged")

    /// Why a title was marked, as the list and the explanation name it.
    package enum Reason: String, Codable, Sendable {
        case deadPicture
        case failedPlayback
        case manual

        package var title: String {
            switch self {
            case .deadPicture: return String(localized: "No picture", comment: "Reason a title was marked incompatible: the server's converted stream arrived as one flat colour")
            case .failedPlayback: return String(localized: "Won't play", comment: "Reason a title was marked incompatible: playback failed")
            case .manual: return String(localized: "Marked by you", comment: "Reason a title was marked incompatible: the viewer asked for it")
            }
        }
    }

    /// One title left out of the app, with what the list needs to show it and what Plex needs to write it back.
    package struct Mark: Codable, Hashable, Sendable, Identifiable {
        package let ratingKey: String
        package let title: String
        package let type: String
        package let thumb: String?
        package let sectionId: String?
        package let reason: Reason
        package let markedAt: Date
        /// Whether the server carries the label; a mark made while the server refused the write is only this device's
        /// until a later pass writes it.
        package var shared: Bool

        package var id: String { ratingKey }

        /// The subtitle the list and the title's own page read: what the title is, and why it was left out.
        package var subtitle: String {
            reason.title
        }
    }

    private static let storagePrefix = "incompatibleTitles.v1."

    private static var storageKey: String {
        storagePrefix + (ServerBootstrap.savedMachineIdentifier ?? "unpaired")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [Mark]?
    nonisolated(unsafe) private static var cachedKeys: Set<String> = []
    nonisolated(unsafe) private static var cachedServer: String?

    /// The marks of the connected server, read once and kept until they change: the filters ask for them for every
    /// card a screen shows. Another server's marks are another server's keys, so they are read again.
    private static func state() -> (marks: [Mark], keys: Set<String>) {
        let server = storageKey
        return lock.withLock {
            if let cached, cachedServer == server { return (cached, cachedKeys) }
            let stored = UserDefaults.standard.data(forKey: server)
                .flatMap { try? JSONDecoder().decode([Mark].self, from: $0) } ?? []
            let keys = Set(stored.map(\.ratingKey))
            cached = stored
            cachedKeys = keys
            cachedServer = server
            return (stored, keys)
        }
    }

    private static var all: [Mark] { state().marks }

    package static var marks: [Mark] {
        all.sorted { $0.markedAt > $1.markedAt }
    }

    package static var count: Int { all.count }

    package static var hiddenKeys: Set<String> { state().keys }

    package static func isHidden(_ ratingKey: String) -> Bool {
        hiddenKeys.contains(ratingKey)
    }

    package static func shows(_ item: PlexMetadata) -> Bool {
        !hides(item)
    }

    /// `items` without the titles this server was told the app cannot play, and without an episode whose series is
    /// marked, since a series left out is left out whole.
    package static func shown(_ items: [PlexMetadata]) -> [PlexMetadata] {
        let keys = hiddenKeys
        guard !keys.isEmpty else { return items }
        return items.filter { item in
            if keys.contains(item.id) { return false }
            if let series = item.grandparentRatingKey, keys.contains(series) { return false }
            if let parent = item.parentRatingKey, keys.contains(parent) { return false }
            return true
        }
    }

    /// Whether the item, its series or its season is marked, which is what the play button and the menus consult.
    package static func hides(_ item: PlexMetadata) -> Bool {
        let keys = hiddenKeys
        guard !keys.isEmpty else { return false }
        if keys.contains(item.id) { return true }
        if let series = item.grandparentRatingKey, keys.contains(series) { return true }
        if let parent = item.parentRatingKey, keys.contains(parent) { return true }
        return false
    }

    @MainActor
    private static func store(_ marks: [Mark]) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        lock.withLock {
            cached = marks
            cachedKeys = Set(marks.map(\.ratingKey))
            cachedServer = storageKey
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    @MainActor
    private static func insert(_ mark: Mark) {
        var marks = all
        marks.removeAll { $0.ratingKey == mark.ratingKey }
        marks.append(mark)
        store(marks)
    }

    @MainActor
    @discardableResult
    private static func remove(_ ratingKey: String) -> Bool {
        var marks = all
        let before = marks.count
        marks.removeAll { $0.ratingKey == ratingKey }
        guard marks.count != before else { return false }
        store(marks)
        return true
    }

    /// Marks a title the app could not play, and writes the label the server keeps so the other devices leave it out
    /// too. The mark answers at once; a server that refuses the write leaves it this device's, and `reconcile` tries
    /// again.
    @MainActor
    package static func mark(_ item: PlexMetadata, reason: Reason, api: APIClient) async {
        await mark(
            ratingKey: item.id,
            title: item.title,
            type: item.mediaType,
            thumb: item.thumb ?? item.grandparentThumb,
            sectionId: item.librarySectionID,
            reason: reason,
            api: api
        )
    }

    /// The same mark for a player, which knows the title it was asked to play and nothing else.
    @MainActor
    package static func mark(
        ratingKey: String,
        title: String,
        type: String,
        thumb: String? = nil,
        sectionId: Int? = nil,
        reason: Reason,
        api: APIClient
    ) async {
        guard !ratingKey.isEmpty else { return }
        let mark = Mark(
            ratingKey: ratingKey,
            title: title,
            type: type,
            thumb: thumb,
            sectionId: sectionId.map { String($0) },
            reason: reason,
            markedAt: Date(),
            shared: false
        )
        insert(mark)
        await write(mark, api: api)
    }

    /// Whether the server took the label for a mark, which the toast after a mark reads.
    package static func isShared(_ ratingKey: String) -> Bool {
        all.first { $0.ratingKey == ratingKey }?.shared ?? false
    }

    @MainActor
    package static func markManually(_ item: PlexMetadata, api: APIClient) async {
        await mark(item, reason: .manual, api: api)
    }

    /// Takes the label off the server and forgets the mark. Throws when the server will not take it off, leaving the
    /// mark where it was so the title stays out until the server agrees.
    @MainActor
    package static func unmark(_ mark: Mark, api: APIClient) async throws {
        let item = try await currentItem(mark.ratingKey, fallbackSection: mark.sectionId, api: api)
        var labels = item.labels
        labels.removeAll { $0 == Self.label }
        try await send(labels, to: item, api: api)
        _ = remove(mark.ratingKey)
    }

    /// Writes the label a mark made on another device, reads what the server carries now, and retries a mark the
    /// server refused. Best effort: a library or label the server does not list simply holds nothing.
    @MainActor
    package static func reconcile(api: APIClient) async {
        for mark in all where !mark.shared {
            await write(mark, api: api)
        }
        let fresh = await labelledItems(api: api)
        let found = Set(fresh.map(\.ratingKey))
        let pending = Set(all.filter { !$0.shared }.map(\.ratingKey))
        var marks = all.filter { mark in
            mark.shared ? found.contains(mark.ratingKey) : pending.contains(mark.ratingKey)
        }
        var known = Set(marks.map(\.ratingKey))
        for mark in fresh where !known.contains(mark.ratingKey) {
            marks.append(mark)
            known.insert(mark.ratingKey)
        }
        guard marks.sorted(by: { $0.ratingKey < $1.ratingKey }) != all.sorted(by: { $0.ratingKey < $1.ratingKey }) else { return }
        store(marks)
    }

    /// Forgets the marks of the server it was connected to: rating keys mean nothing against another one.
    @MainActor
    package static func forgetServer() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        lock.withLock {
            cached = nil
            cachedKeys = []
            cachedServer = nil
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    @MainActor
    package static func restore(_ marks: [Mark]) {
        store(marks)
    }

    @MainActor
    private static func write(_ mark: Mark, api: APIClient) async {
        guard let item = try? await currentItem(mark.ratingKey, fallbackSection: mark.sectionId, api: api) else { return }
        var labels = item.labels
        guard !labels.contains(Self.label) else {
            markShared(mark.ratingKey, true)
            return
        }
        labels.append(Self.label)
        guard (try? await send(labels, to: item, api: api)) != nil else { return }
        markShared(mark.ratingKey, true)
    }

    @MainActor
    private static func markShared(_ ratingKey: String, _ shared: Bool) {
        var marks = all
        guard let index = marks.firstIndex(where: { $0.ratingKey == ratingKey }), marks[index].shared != shared else { return }
        marks[index].shared = shared
        store(marks)
    }

    private struct LabelledItem {
        let ratingKey: String
        let sectionId: String?
        let type: String
        let labels: [String]
    }

    /// Thrown when the server no longer holds the item a mark names, which means there is nothing left to write to.
    private struct MissingItem: LocalizedError {
        var errorDescription: String? { String(localized: "The server no longer has this title.", comment: "Error when a title marked incompatible was deleted from the Plex server") }
    }

    private static func currentItem(_ ratingKey: String, fallbackSection: String?, api: APIClient) async throws -> LabelledItem {
        let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
        guard let item = container.Metadata?.first else { throw MissingItem() }
        return LabelledItem(
            ratingKey: ratingKey,
            sectionId: item.librarySectionID.map { String($0) } ?? fallbackSection,
            type: item.mediaType,
            labels: item.Label?.map(\.tag) ?? []
        )
    }

    private static func send(_ labels: [String], to item: LabelledItem, api: APIClient) async throws {
        guard let section = item.sectionId else { throw MissingItem() }
        try await api.requestConfirmed(.setLabels(
            sectionId: section,
            ratingKey: item.ratingKey,
            type: Self.typeNumber(item.type),
            labels: labels
        ))
    }

    /// Plex's number for the kind of item, which the label write needs.
    private static func typeNumber(_ type: String) -> Int {
        switch type {
        case "show": return 2
        case "season": return 3
        case "episode": return 4
        default: return 1
        }
    }

    /// Every item the server carries the label on, asked one library at a time: the label's value in a library is an
    /// id, so the library lists its labels and the items come back already filtered.
    private static func labelledItems(api: APIClient) async -> [Mark] {
        let sections = await sectionIds(api: api)
        var marks: [Mark] = []
        for section in sections {
            guard let container = try? await api.requestContainer(.sectionFacet(sectionId: section, facet: "label")),
                  let value = container.Directory?.first(where: { $0.title == Self.label })?.key else { continue }
            var start = 0
            while start < 500 {
                guard let page = try? await api.requestContainer(.sectionItems(sectionId: section, start: start, size: 200, filters: ["label": value])) else { break }
                let items = page.Metadata ?? []
                marks += items.compactMap { item in
                    return Mark(
                        ratingKey: item.id,
                        title: item.title,
                        type: item.mediaType,
                        thumb: item.thumb ?? item.grandparentThumb,
                        sectionId: section,
                        reason: .manual,
                        markedAt: Date(timeIntervalSince1970: TimeInterval(item.addedAt ?? 0)),
                        shared: true
                    )
                }
                guard items.count == 200 else { break }
                start += 200
            }
        }
        return marks
    }

    private static func sectionIds(api: APIClient) async -> [String] {
        if !LibraryVisibility.libraries.isEmpty {
            return LibraryVisibility.libraries.map { String($0.id) }
        }
        guard let container = try? await api.requestContainer(.sections) else { return [] }
        return (container.Directory ?? []).compactMap(\.key)
    }
}
