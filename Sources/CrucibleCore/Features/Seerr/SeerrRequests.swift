import Foundation
import MidgarCore

/// One request as the Requests screen lists it: the request, the title it is for and where that title stands.
package struct SeerrRequestEntry: Equatable, Sendable, Identifiable {
    package let request: SeerrRequest
    package let title: String
    package let year: Int?
    package let posterPath: String?
    package let availability: SeerrAvailability
    package let isMine: Bool

    package var id: Int { request.id }

    /// The Plex rating key to play once the title arrived.
    package var ratingKey: String? {
        switch availability {
        case .available, .partiallyAvailable: return request.media?.ratingKey
        default: return nil
        }
    }

    /// The seasons a show's request asked for, as "Seasons 1–3" or "Season 2", nil for a movie.
    package var seasonsLabel: String? {
        let numbers = (request.seasons ?? []).map(\.seasonNumber).sorted()
        guard request.kind == .tv, let first = numbers.first, let last = numbers.last else { return nil }
        if numbers.count == 1 { return String(localized: "Season \(first)", comment: "A show request for one season, e.g. Season 2") }
        if numbers == Array(first...last) { return String(localized: "Seasons \(first)–\(last)", comment: "A show request for a run of seasons, e.g. Seasons 1–3") }
        return String(localized: "\(numbers.count) seasons", comment: "A show request for several seasons that are not a run")
    }
}

/// The requests screen's data: the viewer's own requests, or everyone's for whoever approves them, and the decisions on them.
@MainActor
package final class SeerrRequests {
    package static let shared = SeerrRequests()

    package enum Scope: Sendable {
        case mine
        case everyone
    }

    private let client: SeerrClient
    private let account: SeerrAccount
    private let titles: SeerrTitles
    static let pageSize = 40

    package init(client: SeerrClient = .shared, account: SeerrAccount = .shared, titles: SeerrTitles = .shared) {
        self.client = client
        self.account = account
        self.titles = titles
    }

    /// The newest requests first. `pending` keeps only those waiting for approval.
    package func load(scope: Scope, pendingOnly: Bool = false) async throws -> [SeerrRequestEntry] {
        guard let user = account.connection?.user, account.isConnected else { throw SeerrError.notConnected }
        let everyone = scope == .everyone && user.rights.managesRequests
        let page = try await client.send(
            .requests(take: Self.pageSize, skip: 0, filter: pendingOnly ? "pending" : "all", requestedBy: everyone ? nil : user.id),
            as: SeerrPage<SeerrRequest>.self
        )
        return await entries(for: page.results, viewerID: user.id)
    }

    /// How many requests wait for approval, for the badge on the managers' row.
    package func pendingCount() async -> Int {
        guard account.managesRequests else { return 0 }
        return (try? await client.send(.requests(take: 1, skip: 0, filter: "pending", requestedBy: nil), as: SeerrPage<SeerrRequest>.self))?.pageInfo?.results ?? 0
    }

    /// Each title the page names is looked up once, all of them at the same time.
    private func entries(for requests: [SeerrRequest], viewerID: Int) async -> [SeerrRequestEntry] {
        let keys = Set(requests.compactMap { request in request.kind.flatMap { kind in request.media?.tmdbId.map { TitleKey(kind: kind, tmdbID: $0) } } })
        let lookups = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, Task { try? await titles.details(tmdbID: key.tmdbID, kind: key.kind) })
        })
        var found: [TitleKey: SeerrTitleDetails] = [:]
        for (key, lookup) in lookups { found[key] = await lookup.value }
        var result: [SeerrRequestEntry] = []
        for request in requests {
            guard let kind = request.kind, let tmdbID = request.media?.tmdbId else { continue }
            let details = found[TitleKey(kind: kind, tmdbID: tmdbID)]
            result.append(SeerrRequestEntry(
                request: request,
                title: details?.displayTitle ?? String(localized: "Untitled", comment: "A Seerr request whose title could not be loaded"),
                year: details?.year,
                posterPath: details?.posterPath,
                availability: Self.availability(of: request),
                isMine: request.requestedBy?.id == viewerID
            ))
        }
        return result
    }

    private struct TitleKey: Hashable, Sendable {
        let kind: SeerrMediaKind
        let tmdbID: Int
    }

    /// Where a request's title stands: the request's own refusal or failure first, then the title's availability.
    nonisolated static func availability(of request: SeerrRequest) -> SeerrAvailability {
        switch request.requestStatus {
        case .declined: return .declined
        case .failed: return .failed
        case .pending: return .pending
        case .approved, .completed:
            let state = SeerrAvailability(media: request.media)
            return state == .notRequested || state == .pending ? .approved : state
        }
    }

    /// Withdraws a request; anyone may withdraw their own while it waits, whoever approves requests may remove any.
    package func remove(_ entry: SeerrRequestEntry) async throws {
        try await client.sendVoid(.cancelRequest(id: entry.request.id))
        MidgarLog.notice("Seerr request \(entry.request.id) removed", category: .seerr)
        NotificationCenter.default.post(name: .seerrRequestsChanged, object: nil)
    }

    /// Approves or declines a request waiting for approval.
    package func decide(_ entry: SeerrRequestEntry, approve: Bool) async throws {
        try await client.sendVoid(.moderate(id: entry.request.id, approve: approve))
        MidgarLog.notice("Seerr request \(entry.request.id) \(approve ? "approved" : "declined")", category: .seerr)
        NotificationCenter.default.post(name: .seerrRequestsChanged, object: nil)
    }

    /// Sends a failed request to Sonarr or Radarr again.
    package func retry(_ entry: SeerrRequestEntry) async throws {
        try await client.sendVoid(.retry(id: entry.request.id))
        MidgarLog.notice("Seerr request \(entry.request.id) retried", category: .seerr)
        NotificationCenter.default.post(name: .seerrRequestsChanged, object: nil)
    }
}
