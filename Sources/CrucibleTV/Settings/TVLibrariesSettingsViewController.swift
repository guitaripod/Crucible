import CrucibleCore
import CrucibleDesign
import UIKit

/// Libraries: which libraries count toward Home, Statistics and the tab bar. Select flips a library
/// between On and Off; at least one always stays on. A reset row appears once anything differs
/// from what Plex says.
final class TVLibrariesSettingsViewController: TVSettingsScaffold {
    private static let resetID = "libraries.reset"

    private let api: APIClient
    private var loadTask: Task<Void, Never>?
    private var observer: UUID?

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = "Libraries"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        if let observer {
            Task { @MainActor in LibraryVisibility.removeObserver(observer) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let heading = TVSettingsHeadingView(
            title: "Libraries",
            body: LibrariesSettings.footerText + " Libraries you switch off also leave the tab bar."
        )
        installHeading(heading)
        observer = LibraryVisibility.addObserver { [weak self] in self?.render() }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        load()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override func rowDidSelect(_ id: String) {
        if id == Self.resetID {
            LibraryVisibility.resetToPlexDefaults()
            return
        }
        guard let libraryID = Int(id.dropFirst("library.".count)),
              let row = LibrariesSettings.row(id: libraryID) else { return }
        LibraryVisibility.setIncluded(libraryID, !row.isIncluded)
    }

    private func load() {
        loadTask?.cancel()
        if LibrariesSettings.isLoading {
            showState(.loading(title: LibrariesSettings.loadingTitle))
        }
        loadTask = Task { [weak self, api] in
            await LibrariesSettings.refresh(api: api)
            guard !Task.isCancelled else { return }
            self?.render(afterLoad: true)
        }
    }

    private func render(afterLoad: Bool = false) {
        guard !LibrariesSettings.isLoading else {
            if afterLoad {
                showState(.error(
                    title: "Couldn't Load Libraries",
                    message: "Check the connection to your server and try again.",
                    retryTitle: "Try Again"
                ) { [weak self] in self?.load() })
            }
            return
        }
        showState(nil)
        var rows = LibrariesSettings.rows.map { row in
            TVRowItem(
                id: "library.\(row.id)",
                title: row.title,
                subtitle: row.subtitle,
                value: row.isIncluded ? "On" : "Off",
                symbol: row.symbol,
                isEnabled: !row.isLocked
            )
        }
        if LibrariesSettings.canReset {
            rows.append(TVRowItem(id: Self.resetID, title: LibrariesSettings.resetTitle, symbol: "arrow.counterclockwise"))
        }
        setRows(rows)
    }
}
