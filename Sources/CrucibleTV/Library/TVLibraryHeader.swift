import CrucibleCore
import CrucibleDesign
import UIKit

/// What the header above a library grid shows: the title and count, the watch-filter chips, the
/// Genre and Sort menus and the Browse Folders button.
struct TVLibraryHeaderContent: Hashable {
    struct Choice: Hashable {
        var key: String
        var title: String
        var isSelected: Bool
    }

    struct Handlers: Hashable {
        var onFilter: @MainActor (LibraryWatchFilter) -> Void = { _ in }
        var onGenre: @MainActor (String?) -> Void = { _ in }
        var onSort: @MainActor (String) -> Void = { _ in }
        var onBrowseFolders: @MainActor () -> Void = {}

        static func == (lhs: Handlers, rhs: Handlers) -> Bool { true }
        func hash(into hasher: inout Hasher) {}
    }

    var title: String
    var count: String?
    var chips: [TVChipItem]
    var genreTitle: String
    var isGenreSelected: Bool
    var genres: [Choice]
    var sortTitle: String
    var sorts: [Choice]
    var handlers = Handlers()
}

/// The header block that scrolls above the grid. It is updated in place, so a filter change never
/// rebuilds the view the focus is sitting on.
final class TVLibraryHeaderView: UIView {
    private let titleView = TVScreenTitleView(clearsTabBar: false)
    private let chips = TVChipRow()
    private let genreButton = TVButton.menuButton(style: .chip(selected: false), title: "Genre", menu: UIMenu())
    private let sortButton = TVButton.menuButton(style: .chip(selected: false), title: "Sort", menu: UIMenu())
    private let foldersButton = TVButton.make(.chip(selected: false), title: "Browse Folders", symbol: "folder")
    private let upGuide = UIFocusGuide()
    private var handlers = TVLibraryHeaderContent.Handlers()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        genreButton.accessibilityIdentifier = "tv.library.genre"
        sortButton.accessibilityIdentifier = "tv.library.sort"
        foldersButton.accessibilityIdentifier = "tv.library.folders"
        foldersButton.addAction(UIAction { [weak self] _ in self?.handlers.onBrowseFolders() }, for: .primaryActionTriggered)
        chips.onSelect = { [weak self] item in
            guard let filter = LibraryWatchFilter(rawValue: item.id) else { return }
            self?.handlers.onFilter(filter)
        }

        let controls = UIStackView(arrangedSubviews: [chips, genreButton, sortButton, UIView(), foldersButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = Theme.Space.m
        controls.setCustomSpacing(Theme.Space.l, after: chips)

        let stack = UIStackView(arrangedSubviews: [titleView, controls])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.heightAnchor.constraint(equalToConstant: TVMetrics.Control.chipHeight),
        ])
        installUpGuide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pressing Up from the first poster of a row would otherwise skip the chips and jump to the tab bar;
    /// a guide just under the header sends it to the selected chip instead. It is switched off while the
    /// focus is inside the header: a guide that redirects to the focused chip would trap Down.
    private func installUpGuide() {
        addLayoutGuide(upGuide)
        NSLayoutConstraint.activate([
            upGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            upGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            upGuide.topAnchor.constraint(equalTo: bottomAnchor, constant: Theme.Space.xs),
            upGuide.heightAnchor.constraint(equalToConstant: Theme.Space.m),
        ])
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        upGuide.isEnabled = !(context.nextFocusedView?.isDescendant(of: self) ?? false)
    }

    func configure(_ content: TVLibraryHeaderContent) {
        handlers = content.handlers
        titleView.configure(TVScreenTitleContent(title: content.title, summary: content.count))
        chips.setItems(content.chips)
        upGuide.preferredFocusEnvironments = (chips.items.first { $0.isSelected } ?? chips.items.first).flatMap { chips.button(for: $0.id) }.map { [$0] } ?? []

        genreButton.isHidden = content.genres.isEmpty
        TVButton.configure(menu: genreMenu(content), title: content.genreTitle, style: .chip(selected: content.isGenreSelected), on: genreButton)
        TVButton.configure(menu: sortMenu(content), title: content.sortTitle, style: .chip(selected: false), on: sortButton)
    }

    private func genreMenu(_ content: TVLibraryHeaderContent) -> UIMenu {
        let all = UIAction(title: "All Genres", state: content.isGenreSelected ? .off : .on) { [weak self] _ in
            self?.handlers.onGenre(nil)
        }
        let genres = content.genres.map { genre in
            UIAction(title: genre.title, state: genre.isSelected ? .on : .off) { [weak self] _ in
                self?.handlers.onGenre(genre.key)
            }
        }
        return UIMenu(title: "Genre", children: [all] + genres)
    }

    private func sortMenu(_ content: TVLibraryHeaderContent) -> UIMenu {
        UIMenu(title: "Sort By", children: content.sorts.map { sort in
            UIAction(title: sort.title, state: sort.isSelected ? .on : .off) { [weak self] _ in
                self?.handlers.onSort(sort.key)
            }
        })
    }
}

extension TVHostCell {
    /// Shows the Library header. The hosted view is kept between configurations, so a refresh never
    /// rebuilds the button the focus is on.
    func showLibraryHeader(_ content: TVLibraryHeaderContent) {
        let header = (hosted as? TVLibraryHeaderView) ?? {
            let created = TVLibraryHeaderView()
            host(created)
            return created
        }()
        header.configure(content)
    }
}
