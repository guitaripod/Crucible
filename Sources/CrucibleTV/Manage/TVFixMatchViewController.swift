import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// Fix Match on Apple TV: the server's agents are searched for the right movie or show, starting from the title as it is, and
/// the one picked is matched. The first row edits the search; a year typed after the name ("Dune 2021") narrows it.
final class TVFixMatchViewController: TVSettingsScaffold {
    private static let searchID = "fixMatch.search"
    private static let retryID = "fixMatch.retry"
    private static let resultPrefix = "fixMatch.result."

    private let item: PlexMetadata
    private let api: APIClient
    private let onMatched: @MainActor () -> Void
    private let heading: TVSettingsHeading
    private var query: String
    private var results: [PlexMatchResult] = []
    private var failure: String?
    private var isSearching = true
    private lazy var searchSlot = makeTaskSlot()

    init(item: PlexMetadata, api: APIClient, onMatched: @escaping @MainActor () -> Void) {
        self.item = item
        self.api = api
        self.onMatched = onMatched
        query = MatchQuery.text(for: item)
        heading = TVSettingsHeading(
            title: String(localized: "Fix Match", comment: "Title of the Fix Match screen"),
            body: String(localized: "Pick the right movie or show for \(item.title).", comment: "Fix Match explanation, e.g. Pick the right movie or show for Dune.")
        )
        super.init()
        title = String(localized: "Fix Match", comment: "Title of the Fix Match screen")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        render()
        search()
    }

    override func rowDidSelect(_ id: String) {
        switch id {
        case Self.searchID:
            presentTextEntry(
                title: String(localized: "Title and year", comment: "Placeholder of the Fix Match search field"),
                text: query,
                confirmTitle: String(localized: "Search", comment: "Button that runs a search")
            ) { [weak self] text in
                self?.query = text
                self?.search()
            }
        case Self.retryID:
            search()
        default:
            guard let result = results.first(where: { Self.resultPrefix + $0.guid == id }) else { return }
            confirm(result)
        }
    }

    private func search() {
        let parsed = MatchQuery(parsing: query)
        isSearching = true
        failure = nil
        render()
        searchSlot.run { [weak self] in
            guard let self else { return }
            do {
                let found = try await LibraryManagement.matches(ratingKey: item.id, title: parsed.name, year: parsed.year, api: api)
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Fix Match search failed for \(item.id): \(error.localizedDescription)", category: .networking)
                results = []
                failure = ConnectionError.message(for: error)
            }
            isSearching = false
            render()
        }
    }

    private func confirm(_ result: PlexMatchResult) {
        let name = Self.name(result)
        presentConfirmation(
            title: String(localized: "Match to \(name)?", comment: "Fix Match confirmation title, e.g. Match to Dune (2021)?"),
            message: String(localized: "The title takes this one's details, artwork and ratings.", comment: "Fix Match confirmation message"),
            confirmTitle: String(localized: "Match", comment: "Button that confirms a Fix Match choice")
        ) { [weak self] in
            guard let self else { return }
            let api = api
            let key = item.id
            let onMatched = onMatched
            Task { @MainActor [weak self] in
                do {
                    try await LibraryManagement.match(ratingKey: key, to: result, api: api)
                    if let self { TVNavigation.pop(from: self) }
                    try? await Task.sleep(for: .seconds(2))
                    onMatched()
                } catch {
                    self?.presentAlert(title: ManageCopy.failed, message: ConnectionError.message(for: error))
                }
            }
        }
    }

    private func render() {
        var rows = [TVRowItem(id: Self.searchID, title: String(localized: "Search", comment: "Button that runs a search"), value: query, symbol: "magnifyingglass")]
        if isSearching {
            rows.append(TVRowItem(id: "fixMatch.searching", title: String(localized: "Searching…", comment: "Fix Match status while the server's agents are searched"), symbol: "hourglass", isStatic: true))
        } else if let failure {
            rows.append(TVRowItem(id: "fixMatch.failed", title: ManageCopy.failed, subtitle: failure, symbol: "exclamationmark.triangle", isStatic: true))
            rows.append(TVRowItem(id: Self.retryID, title: String(localized: "Try Again"), symbol: "arrow.clockwise"))
        } else if results.isEmpty {
            rows.append(TVRowItem(
                id: "fixMatch.none",
                title: String(localized: "No Matches", comment: "Fix Match empty state title"),
                subtitle: String(localized: "Try the original title, or add the year.", comment: "Fix Match empty state message"),
                symbol: "film",
                isStatic: true
            ))
        } else {
            rows += results.map { result in
                TVRowItem(
                    id: Self.resultPrefix + result.guid,
                    title: Self.name(result),
                    value: result.score.map { String(localized: "\($0)% match", comment: "How sure the server's agent is of a Fix Match result, e.g. 92% match") },
                    symbol: "film",
                    accessory: result.matched == true ? .checkmark : .none
                )
            }
        }
        setRows(rows)
    }

    private static func name(_ result: PlexMatchResult) -> String {
        [result.name, result.year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
}
