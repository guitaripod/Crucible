import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The titles the app left out because the server's copy cannot play here (`IncompatibleTitles`), and the way back:
/// Select puts a title into Home, search and the libraries again, on every device of the same Plex server.
@MainActor
final class IncompatibleTitlesScreen: SettingsScaffold {
    private let api: APIClient
    private let state = StateView()
    private var observer: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var working = Set<String>()

    init(api: APIClient) {
        self.api = api
        super.init(title: IncompatibleCopy.title, detail: IncompatibleCopy.footer)
        addSubview(state)
        state.isHidden = true
        render()
    }

    override var preferredFocusView: View? { state.isHidden ? rows : state }

    override func screenDidAppear() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: IncompatibleTitles.changed,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }
        load()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
        loadTask = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    override func rowSelected(_ id: String) {
        guard !working.contains(id), let mark = IncompatibleTitles.marks.first(where: { $0.ratingKey == id }) else { return }
        working.insert(id)
        render()
        loadTask = Task { [weak self, api] in
            defer {
                self?.working.remove(id)
                self?.render()
            }
            do {
                try await IncompatibleTitles.unmark(mark, api: api)
            } catch {
                self?.show(.error(
                    title: IncompatibleCopy.unmark,
                    message: ConnectionError.message(for: error),
                    retryTitle: String(localized: "OK", comment: "Button that closes an error"),
                    retry: { [weak self] in self?.render() }
                ))
            }
        }
    }

    private func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self, api] in
            if IncompatibleTitles.count == 0 { self?.show(.loading(title: IncompatibleCopy.title)) }
            await IncompatibleTitles.reconcile(api: api)
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    private func render() {
        let marks = IncompatibleTitles.marks
        guard !marks.isEmpty else {
            show(.empty(title: IncompatibleCopy.emptyTitle, message: IncompatibleCopy.emptyExplanation, symbol: "exclamationmark.triangle", action: nil))
            return
        }
        setRows(marks.map { mark in
            RowItem(
                id: mark.ratingKey,
                title: mark.title,
                subtitle: mark.shared ? mark.subtitle : mark.subtitle + " · " + IncompatibleCopy.thisDeviceOnly,
                value: working.contains(mark.ratingKey) ? nil : IncompatibleCopy.unmark,
                symbol: Symbol(mark.type == "episode" ? "tv" : "exclamationmark.triangle")
            )
        })
        rows.isHidden = false
        state.isHidden = true
    }

    private func show(_ newState: StateView.State) {
        state.show(newState)
        state.isHidden = false
        rows.isHidden = true
        if window?.focusedView == nil { window?.focus.focus(state, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        state.frame = bounds
    }
}
