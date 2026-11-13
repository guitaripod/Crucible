import Foundation
import MidgarCore

/// What What to Watch is doing, for the line beside the spinner.
package enum WatchStep: Equatable, Sendable {
    case readingLibrary
    case understanding
    case choosing
}

/// Why no picks came back, each with its own next step for the person.
package enum WatchFailure: Error, Equatable, Sendable {
    case emptyLibrary
    case libraryUnreachable
    /// Nothing in the library passes what was asked; the model's own sentence about what is missing, when it gave one.
    case nothingFits(note: String)
    case brain(HostedBrainError)
}

/// The picks for one request, with the Plex items they stand for so a screen can show and open them.
package struct WatchAnswer: Sendable {
    package let request: String
    package let picks: [WatchPick]
    package let note: String
    package let items: [String: PlexMetadata]

    package func item(for pick: WatchPick) -> PlexMetadata? {
        items[pick.id]
    }
}

/// What to Watch: a sentence becomes picks from the person's own films and series through two calls to Crucible's
/// hosted model. The first turns the sentence into limits that code applies, the second chooses among the numbered
/// titles that pass. Titles, years, genres, lengths, ratings and watched state are what is sent; nothing else is.
package actor WatchSession {
    package struct Environment: Sendable {
        package var loadLibrary: @Sendable () async throws -> [PlexMetadata]
        package var ask: @Sendable (_ alias: String, _ input: String) async throws(HostedBrainError) -> String
        package var year: @Sendable () -> Int
        package var now: @Sendable () -> Date
        /// The libraries the person has hidden, read at each request so a copy read before one was hidden is not used.
        package var hiddenLibraries: @Sendable () -> Set<Int>

        package init(
            loadLibrary: @escaping @Sendable () async throws -> [PlexMetadata],
            ask: @escaping @Sendable (_ alias: String, _ input: String) async throws(HostedBrainError) -> String,
            year: @escaping @Sendable () -> Int = { Calendar(identifier: .gregorian).component(.year, from: Date()) },
            now: @escaping @Sendable () -> Date = { Date() },
            hiddenLibraries: @escaping @Sendable () -> Set<Int> = { LibraryVisibility.excluded }
        ) {
            self.loadLibrary = loadLibrary
            self.ask = ask
            self.year = year
            self.now = now
            self.hiddenLibraries = hiddenLibraries
        }
    }

    private static let pageSize = 200
    private static let sectionCeiling = 12_000
    private static let libraryLifetime: TimeInterval = 600

    private let environment: Environment
    private var library: (items: [PlexMetadata], loadedAt: Date, hidden: Set<Int>)?

    package init(environment: Environment) {
        self.environment = environment
    }

    package init(api: APIClient) {
        self.init(environment: Environment(
            loadLibrary: { try await Self.library(api: api) },
            ask: { alias, input async throws(HostedBrainError) in try await HostedBrain.ask(alias: alias, input: input) }
        ))
    }

    /// Picks for `request`. `progress` is called as each step begins.
    package func answer(_ request: String, progress: @Sendable (WatchStep) -> Void) async -> Result<WatchAnswer, WatchFailure> {
        progress(.readingLibrary)
        let items: [PlexMetadata]
        do {
            items = try await currentLibrary()
        } catch {
            MidgarLog.notice("What to Watch could not read the library: \(error)", category: .networking)
            return .failure(.libraryUnreachable)
        }
        let titles = items.compactMap(WatchTitle.init)
        guard !titles.isEmpty else { return .failure(.emptyLibrary) }

        progress(.understanding)
        let plan: WatchPlan
        do {
            let reply = try await environment.ask(WatchPicker.planAlias, WatchPicker.planInput(request, year: environment.year()))
            guard let read = WatchPicker.plan(from: reply) else { return .failure(.brain(.failed)) }
            plan = read
        } catch {
            return .failure(.brain(error))
        }
        let candidates = WatchPicker.offered(request, plan: plan, candidates: WatchPicker.candidates(for: plan, in: titles))
        guard !candidates.isEmpty else { return .failure(.nothingFits(note: "")) }

        progress(.choosing)
        do {
            let reply = try await environment.ask(WatchPicker.pickAlias, WatchPicker.pickInput(request, plan: plan, candidates: candidates))
            guard let chosen = WatchPicker.picks(from: reply, candidates: candidates, plan: plan) else { return .failure(.brain(.failed)) }
            guard !chosen.picks.isEmpty else { return .failure(.nothingFits(note: chosen.note)) }
            MidgarLog.info("What to Watch chose \(chosen.picks.count) of \(candidates.count) candidates from \(titles.count) titles", category: .networking)
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return .success(WatchAnswer(request: WatchPicker.cleaned(request), picks: chosen.picks, note: chosen.note, items: byID))
        } catch {
            return .failure(.brain(error))
        }
    }

    /// The library, read again when the copy held is older than ten minutes or was read under another choice of
    /// hidden libraries.
    private func currentLibrary() async throws -> [PlexMetadata] {
        let hidden = environment.hiddenLibraries()
        if let library, library.hidden == hidden, environment.now().timeIntervalSince(library.loadedAt) < Self.libraryLifetime { return library.items }
        let items = try await environment.loadLibrary()
        library = (items, environment.now(), hidden)
        return items
    }

    /// Every film and series of the libraries the person has not hidden, a page at a time and each title once. A
    /// library is read newest addition first, so one past the ceiling leaves out what was added longest ago.
    package static func library(api: APIClient) async throws -> [PlexMetadata] {
        let sections = try await LibrarySection.load(api: api)
        let included = await MainActor.run { sections.filter { section in Int(section.id).map(LibraryVisibility.isIncluded) ?? true } }
        var all: [PlexMetadata] = []
        var held = Set<String>()
        for section in included {
            var start = 0
            var reachedEnd = false
            while start < sectionCeiling, !reachedEnd {
                try Task.checkCancellation()
                let container = try await api.requestContainer(.sectionItems(sectionId: section.id, sort: "addedAt:desc", start: start, size: pageSize))
                let page = container.Metadata ?? []
                all.append(contentsOf: page.filter { held.insert($0.id).inserted })
                start += pageSize
                reachedEnd = page.count < pageSize || (container.totalSize.map { start >= $0 } ?? false)
            }
            if !reachedEnd {
                MidgarLog.notice("What to Watch read the newest \(sectionCeiling) titles of library \(section.id) and left out the rest", category: .networking)
            }
        }
        return all
    }
}
