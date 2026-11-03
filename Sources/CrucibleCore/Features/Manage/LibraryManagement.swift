import Foundation
import MidgarCore

/// A poster or a background, the two pictures of a title the owner can choose between.
package enum ArtworkKind: String, Sendable {
    case poster
    case background

    var listPath: String { self == .poster ? "posters" : "arts" }
    var selectPath: String { self == .poster ? "poster" : "art" }

    package var chooseTitle: String {
        self == .poster
            ? String(localized: "Choose Poster…", comment: "Menu item that opens the poster picker of a title")
            : String(localized: "Choose Background…", comment: "Menu item that opens the background picker of a title")
    }
}

/// A candidate the server's agents found for Fix Match.
package struct PlexMatchResult: Decodable, Sendable, Hashable, Identifiable {
    package let guid: String
    package let name: String
    package let year: Int?
    package let score: Int?
    package let thumb: String?
    package let matched: Bool?

    package var id: String { guid }

    enum CodingKeys: String, CodingKey { case guid, name, year, score, thumb, matched }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decode(String.self, forKey: .guid)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        year = PlexNumber.decode(container, .year, Int.self)
        score = PlexNumber.decode(container, .score, Int.self)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        matched = (try? container.decodeIfPresent(Bool.self, forKey: .matched)) ?? nil
    }

    package init(guid: String, name: String, year: Int?, score: Int?, thumb: String?, matched: Bool?) {
        self.guid = guid
        self.name = name
        self.year = year
        self.score = score
        self.thumb = thumb
        self.matched = matched
    }
}

/// A picture the server offers for a title's poster or background.
package struct PlexArtworkChoice: Decodable, Sendable, Hashable, Identifiable {
    package let key: String?
    package let ratingKey: String
    package let thumb: String?
    package let selected: Bool?
    package let provider: String?

    package var id: String { ratingKey }

    /// What to load to show the choice: its small version when the server has one.
    package var imagePath: String? { thumb ?? key }
}

/// Something the server is busy with: a scan, a refresh, an optimisation.
package struct PlexActivity: Decodable, Sendable, Hashable, Identifiable {
    package let uuid: String
    package let type: String?
    package let cancellable: Bool?
    package let title: String?
    package let subtitle: String?
    package let progress: Int?

    package var id: String { uuid }

    enum CodingKeys: String, CodingKey { case uuid, type, cancellable, title, subtitle, progress }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        cancellable = (try? container.decodeIfPresent(Bool.self, forKey: .cancellable)) ?? nil
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        progress = PlexNumber.decode(container, .progress, Int.self)
    }
}

/// A server version the updater offers, with its release notes.
package struct PlexServerRelease: Decodable, Sendable, Hashable {
    package let version: String?
    package let added: String?
    package let fixed: String?
    package let state: String?
}

/// The server's own load at one moment, as percentages.
package struct PlexResourceSample: Decodable, Sendable, Hashable {
    package let at: Int?
    package let hostCpuUtilization: Double?
    package let processCpuUtilization: Double?
    package let hostMemoryUtilization: Double?
    package let processMemoryUtilization: Double?
}

private struct ManagementContainer: Decodable {
    let MediaContainer: Body

    struct Body: Decodable {
        let SearchResult: [PlexMatchResult]?
        let Metadata: [PlexArtworkChoice]?
        let Activity: [PlexActivity]?
        let Release: [PlexServerRelease]?
        let StatisticsResources: [PlexResourceSample]?
        let canInstall: Bool?
    }
}

/// What the server's owner can do to its libraries and titles from Crucible: scan, refresh, analyze, fix a match, edit the
/// details, pick artwork, delete; and what the server dashboard shows: its tasks, its load and its updates.
package enum LibraryManagement {
    package static func scan(sectionId: String, force: Bool, api: APIClient) async throws {
        try await perform(.scanSection(sectionId: sectionId, force: force), api: api)
    }

    package static func analyze(sectionId: String, api: APIClient) async throws {
        try await perform(.analyzeSection(sectionId: sectionId), api: api)
    }

    package static func emptyTrash(sectionId: String, api: APIClient) async throws {
        try await perform(.emptyTrash(sectionId: sectionId), api: api)
    }

    package static func refresh(ratingKey: String, api: APIClient) async throws {
        try await perform(.refreshItem(ratingKey: ratingKey), api: api)
        await api.invalidate(ratingKey: ratingKey)
    }

    package static func analyze(ratingKey: String, api: APIClient) async throws {
        try await perform(.analyzeItem(ratingKey: ratingKey), api: api)
    }

    package static func matches(ratingKey: String, title: String?, year: Int?, api: APIClient) async throws -> [PlexMatchResult] {
        let container: ManagementContainer = try await api.request(.matches(ratingKey: ratingKey, title: title, year: year))
        return (container.MediaContainer.SearchResult ?? []).sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }

    package static func match(ratingKey: String, to result: PlexMatchResult, api: APIClient) async throws {
        try await perform(.match(ratingKey: ratingKey, guid: result.guid, name: result.name, year: result.year), api: api)
        await api.invalidate(ratingKey: ratingKey)
    }

    package static func unmatch(ratingKey: String, api: APIClient) async throws {
        try await perform(.unmatch(ratingKey: ratingKey), api: api)
        await api.invalidate(ratingKey: ratingKey)
    }

    /// Saves edited fields and locks them, so the next metadata refresh keeps them.
    package static func edit(_ edit: MetadataEdit, api: APIClient) async throws {
        let values = edit.changedValues
        guard !values.isEmpty else { return }
        try await perform(.editFields(sectionId: edit.sectionId, ratingKey: edit.ratingKey, type: edit.typeNumber, values: values), api: api)
        await api.invalidate(ratingKey: edit.ratingKey)
    }

    package static func artwork(ratingKey: String, kind: ArtworkKind, api: APIClient) async throws -> [PlexArtworkChoice] {
        let container: ManagementContainer = try await api.request(.artwork(ratingKey: ratingKey, kind: kind))
        return container.MediaContainer.Metadata ?? []
    }

    package static func select(_ choice: PlexArtworkChoice, kind: ArtworkKind, ratingKey: String, api: APIClient) async throws {
        try await perform(.selectArtwork(ratingKey: ratingKey, kind: kind, url: choice.ratingKey), api: api)
        await api.invalidate(ratingKey: ratingKey)
    }

    package static func delete(ratingKey: String, api: APIClient) async throws {
        try await perform(.deleteItem(ratingKey: ratingKey), api: api)
        await api.invalidateCache()
    }

    package static func stopStream(sessionId: String, reason: String, api: APIClient) async throws {
        try await perform(.terminateSession(sessionId: sessionId, reason: reason), api: api)
    }

    package static func activities(api: APIClient) async throws -> [PlexActivity] {
        let container: ManagementContainer = try await api.request(.activities)
        return container.MediaContainer.Activity ?? []
    }

    package static func cancel(_ activity: PlexActivity, api: APIClient) async throws {
        try await perform(.cancelActivity(uuid: activity.uuid), api: api)
    }

    /// The newest release the updater offers, or nil when the server is up to date.
    package static func availableUpdate(api: APIClient) async throws -> PlexServerRelease? {
        let container: ManagementContainer = try await api.request(.updaterStatus)
        return container.MediaContainer.Release?.first { $0.state != "installed" && $0.version != nil }
    }

    package static func checkForUpdates(api: APIClient) async throws {
        try await perform(.updaterCheck, api: api)
    }

    package static func installUpdate(api: APIClient) async throws {
        try await perform(.updaterApply, api: api)
    }

    /// The server's newest load sample.
    package static func load(api: APIClient) async throws -> PlexResourceSample? {
        let container: ManagementContainer = try await api.request(.resourceStatistics)
        return container.MediaContainer.StatisticsResources?.max { ($0.at ?? 0) < ($1.at ?? 0) }
    }

    package static func deleteHistoryEntry(historyKey: String, api: APIClient) async throws {
        guard let id = historyKey.split(separator: "/").last.map(String.init) else { return }
        try await perform(.deleteHistoryEntry(historyId: id), api: api)
    }

    private static func perform(_ endpoint: PlexEndpoint, api: APIClient) async throws {
        do {
            try await api.requestConfirmed(endpoint)
        } catch {
            MidgarLog.error("Manage \(endpoint.path) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }
}

/// The details of a title the owner can edit. Only the fields that changed are sent, and each one sent is locked.
package struct MetadataEdit: Sendable, Equatable {
    package let ratingKey: String
    package let sectionId: String
    package let mediaType: String
    package var title: String
    package var sortTitle: String
    package var originalTitle: String
    package var summary: String
    package var year: String
    private let original: [String: String]

    package init(item: PlexMetadata, sectionId: String) {
        ratingKey = item.id
        self.sectionId = sectionId
        mediaType = item.mediaType
        title = item.title
        sortTitle = item.titleSort ?? ""
        originalTitle = item.originalTitle ?? ""
        summary = item.summary ?? ""
        year = item.year.map(String.init) ?? ""
        original = ["title": title, "titleSort": sortTitle, "originalTitle": originalTitle, "summary": summary, "year": year]
    }

    /// Plex's number for the type, which the edit call needs.
    package var typeNumber: Int {
        switch mediaType {
        case "movie": return 1
        case "show": return 2
        case "season": return 3
        case "episode": return 4
        default: return 1
        }
    }

    package var editsYear: Bool { mediaType == "movie" }

    package var changedValues: [String: String] {
        var values = ["title": title, "titleSort": sortTitle, "originalTitle": originalTitle, "summary": summary]
        if editsYear { values["year"] = year }
        return values.filter { original[$0.key] != $0.value && !($0.key == "title" && $0.value.trimmingCharacters(in: .whitespaces).isEmpty) }
    }
}

/// Whether the signed-in account owns the connected server. Only the owner may scan, match, edit, delete or stop someone's
/// stream, so those tools stay hidden for everyone else. Remembered per server and refreshed after each launch.
@MainActor
package enum ServerOwnership {
    private static let storageKey = "serverOwnership.v1"

    package static func isOwner(machineIdentifier: String? = ServerBootstrap.savedMachineIdentifier) -> Bool {
        guard let machineIdentifier else { return false }
        return stored()[machineIdentifier] ?? false
    }

    /// Asks plex.tv which servers the account owns and remembers the answer for `machineIdentifier`.
    @discardableResult
    package static func refresh(token: String, machineIdentifier: String) async -> Bool {
        guard let resources: [PlexResource] = try? await APIClient.plexTVRequest(.resources, token: token),
              let server = resources.first(where: { $0.clientIdentifier == machineIdentifier }) else {
            return isOwner(machineIdentifier: machineIdentifier)
        }
        var all = stored()
        all[machineIdentifier] = server.owned ?? false
        UserDefaults.standard.set(all, forKey: storageKey)
        return server.owned ?? false
    }

    #if DEBUG
    package static func setForTesting(_ owned: Bool, machineIdentifier: String) {
        var all = stored()
        all[machineIdentifier] = owned
        UserDefaults.standard.set(all, forKey: storageKey)
    }
    #endif

    private static func stored() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Bool] ?? [:]
    }
}

/// Copy for the owner tools.
package enum ManageCopy {
    package static let menuTitle = String(localized: "Manage", comment: "Submenu of the server owner's tools for a title or library")
    package static let refreshMetadata = String(localized: "Refresh Metadata", comment: "Owner tool: fetch a title's metadata again")
    package static let analyze = String(localized: "Analyze", comment: "Owner tool: analyze a title's media files")
    package static let fixMatch = String(localized: "Fix Match…", comment: "Owner tool: match a title to the right movie or show")
    package static let unmatch = String(localized: "Unmatch", comment: "Owner tool: remove a title's match")
    package static let editDetails = String(localized: "Edit Details…", comment: "Owner tool: edit a title's name and summary")
    package static let delete = String(localized: "Delete from Server…", comment: "Owner tool: delete a title's files from the server")
    package static let scanLibrary = String(localized: "Scan Library Files", comment: "Owner tool: look for new files in a library")
    package static let refreshLibrary = String(localized: "Refresh All Metadata", comment: "Owner tool: refresh every title in a library")
    package static let analyzeLibrary = String(localized: "Analyze Library", comment: "Owner tool: analyze every file in a library")
    package static let emptyTrash = String(localized: "Empty Trash", comment: "Owner tool: forget a library's missing files")
    package static let done = String(localized: "Sent to Your Server", comment: "Confirmation after an owner tool was sent to the server")
    package static let failed = String(localized: "Your Server Said No", comment: "Alert title when the server refused an owner tool")

    package static func deleteMessage(_ title: String) -> String {
        String(localized: "This deletes the files of \(title) from your server's disk. It cannot be undone, and the server only allows it when Allow Media Deletion is on in its settings.", comment: "Confirmation message for deleting a title from the server")
    }

    package static let refreshLibraryMessage = String(localized: "Every title in this library is looked up again. On a big library this takes a while and keeps the server busy.", comment: "Confirmation message for refreshing a whole library")
    package static let emptyTrashMessage = String(localized: "Titles whose files are gone leave the library for good.", comment: "Confirmation message for emptying a library's trash")
    package static let stopStream = String(localized: "Stop Stream…", comment: "Owner tool: end someone's playback")
    package static let stopReasons = [
        String(localized: "The server needs a break.", comment: "Preset reason shown to someone whose stream the owner stopped"),
        String(localized: "Too many streams at once right now.", comment: "Preset reason shown to someone whose stream the owner stopped"),
        String(localized: "Maintenance, back soon.", comment: "Preset reason shown to someone whose stream the owner stopped"),
    ]
}
