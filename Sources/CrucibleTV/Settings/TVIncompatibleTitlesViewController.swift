import CrucibleCore
import CrucibleDesign
import UIKit

/// The titles the app left out because the server's copy cannot play here, on the Apple TV: Select puts a title back
/// into Home, search and the libraries, on every device of the same Plex server.
final class TVIncompatibleTitlesViewController: TVSettingsScaffold {
    private let api: APIClient
    private lazy var loadSlot = makeTaskSlot()
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(api: APIClient) {
        self.api = api
        super.init()
        title = IncompatibleCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(TVSettingsHeading(title: IncompatibleCopy.title, body: IncompatibleCopy.footer))
        observer = NotificationCenter.default.addObserver(
            forName: IncompatibleTitles.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        load()
    }

    override func rowDidSelect(_ id: String) {
        guard let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == id }) else { return }
        Haptics.light()
        Task { [weak self, api] in
            do {
                try await IncompatibleTitles.unmark(mark, api: api)
            } catch {
                Haptics.error()
                self?.presentFailure(error)
            }
        }
    }

    private func load() {
        loadSlot.run { [weak self, api] in
            await IncompatibleTitles.reconcile(api: api)
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    private func render() {
        let marks = IncompatibleTitles.marks
        guard !marks.isEmpty else {
            presentState(.empty(
                title: IncompatibleCopy.emptyTitle,
                message: IncompatibleCopy.emptyExplanation,
                symbol: "exclamationmark.triangle",
                action: nil
            ))
            return
        }
        presentState(nil)
        setRows(marks.map { mark in
            TVRowItem(
                id: mark.ratingKey,
                title: mark.title,
                subtitle: mark.shared ? mark.subtitle : mark.subtitle + " · " + IncompatibleCopy.thisDeviceOnly,
                value: IncompatibleCopy.unmark,
                symbol: mark.type == "episode" ? "tv" : "exclamationmark.triangle"
            )
        })
    }

    private func presentFailure(_ error: Error) {
        presentState(.error(
            title: IncompatibleCopy.unmark,
            message: ConnectionError.message(for: error),
            retryTitle: String(localized: "OK"),
            retry: { [weak self] in self?.render() },
            secondary: nil
        ))
    }
}
