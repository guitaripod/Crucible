import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The More tab (`TVMoreViewController`): the libraries that did not fit in the tab bar, as tiles with their kind and item
/// count. Selecting a tile opens that library.
@MainActor
final class MoreScreen: ScreenView {
    private let api: APIClient
    private let libraries: [PlexDirectory]
    private let page = PageView()
    private let heading = ScreenTitleView(title: String(localized: "More Libraries"))
    private let tiles = CardGridView()
    private let state = StateView()
    private var counts: [String: Int] = [:]
    private var countTask: Task<Void, Never>?

    init(api: APIClient, libraries: [PlexDirectory]) {
        self.api = api
        self.libraries = libraries.filter { $0.key != nil }
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, tiles])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        tiles.aspect = 9 / 16
        tiles.onActivate = { [weak self] tile in self?.open(key: tile.id) }
        if self.libraries.isEmpty {
            state.show(.empty(title: String(localized: "No More Libraries"), message: String(localized: "Every library is in the tab bar."),
                              symbol: "rectangle.stack", action: nil))
        } else {
            state.isHidden = true
        }
        showTiles()
    }

    override var preferredFocusView: View? { state.isHidden ? tiles : state }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        loadCounts()
    }

    override func screenWillDisappear() {
        countTask?.cancel()
    }

    private func showTiles() {
        tiles.setItems(libraries.compactMap(tile))
        page.setNeedsLayout()
    }

    private func tile(_ directory: PlexDirectory) -> CardItem? {
        guard let key = directory.key else { return nil }
        let kind = LibraryGridKind(sectionType: directory.type)
        let subtitle = counts[key].map { count -> String in
            let formatted = count.formatted(.number)
            switch (kind == .show, count == 1) {
            case (true, true): return String(localized: "\(formatted) show")
            case (true, false): return String(localized: "\(formatted) shows")
            case (false, true): return String(localized: "\(formatted) movie")
            case (false, false): return String(localized: "\(formatted) movies")
            }
        } ?? kind?.defaultTitle
        return CardItem(id: key, title: directory.title ?? String(localized: "Library"), subtitle: subtitle,
                        placeholderSymbol: Symbol(kind?.placeholderIcon ?? "film"))
    }

    /// Fetches each library's item count with a zero-size page, which carries only the total.
    private func loadCounts() {
        countTask?.cancel()
        let keys = libraries.compactMap(\.key)
        let api = api
        countTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int?).self) { group in
                for key in keys {
                    group.addTask {
                        let container = try? await api.requestContainer(.sectionItems(sectionId: key, size: 0))
                        return (key, container?.totalSize)
                    }
                }
                for await (key, total) in group {
                    guard !Task.isCancelled, let self, let total, self.counts[key] != total else { continue }
                    self.counts[key] = total
                    self.showTiles()
                }
            }
        }
    }

    private func open(key: String) {
        guard let directory = libraries.first(where: { $0.key == key }) else { return }
        rootView?.push(LibraryScreen(api: api, directory: directory))
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}
