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

    struct FacetMenu: Hashable {
        var facet: LibraryFacet
        var choices: [Choice]
        var selectedKey: String?
    }

    struct Handlers: Hashable {
        var onFacet: @MainActor (LibraryFacet, String?) -> Void = { _, _ in }
        var onFilter: @MainActor (LibraryWatchFilter) -> Void = { _ in }
        var onGenre: @MainActor (String?) -> Void = { _ in }
        var onSort: @MainActor (String) -> Void = { _ in }
        var onBrowseFolders: @MainActor () -> Void = {}
        var onCollections: @MainActor () -> Void = {}
        var manageMenu: @MainActor () -> UIMenu? = { nil }

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
    var facets: [FacetMenu] = []
    var showsManage = false
    var handlers = Handlers()
}

/// The header block that scrolls above the grid. It is updated in place, so a filter change never
/// rebuilds the view the focus is sitting on.
final class TVLibraryHeaderView: UIView {
    private let titleView = TVScreenTitleView(clearsTabBar: false)
    private let chips = TVChipRow()
    private let genreButton = TVButton.menuButton(style: .chip(selected: false), title: String(localized: "Genre"), menu: UIMenu())
    private let sortButton = TVButton.menuButton(style: .chip(selected: false), title: String(localized: "Sort", comment: "Button that opens the sort menu, not the verb"), menu: UIMenu())
    private let foldersButton = TVButton.make(.chip(selected: false), title: String(localized: "Folders", comment: "Short name of the button that browses a library by its folders"), symbol: "folder")
    private let filtersButton = TVButton.menuButton(style: .chip(selected: false), title: String(localized: "Filters", comment: "Button that opens the menu of extra library filters"), menu: UIMenu())
    private let collectionsButton = TVButton.make(.chip(selected: false), title: String(localized: "Collections"), symbol: "rectangle.stack")
    private let manageButton = TVButton.menuButton(style: .chip(selected: false), title: ManageCopy.menuTitle, menu: UIMenu())
    private let upGuide = UIFocusGuide()
    private var handlers = TVLibraryHeaderContent.Handlers()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        genreButton.accessibilityIdentifier = "tv.library.genre"
        sortButton.accessibilityIdentifier = "tv.library.sort"
        foldersButton.accessibilityIdentifier = "tv.library.folders"
        foldersButton.accessibilityLabel = String(localized: "Browse Folders")
        collectionsButton.accessibilityIdentifier = "tv.library.collections"
        filtersButton.accessibilityIdentifier = "tv.library.filters"
        manageButton.accessibilityIdentifier = "tv.library.manage"
        collectionsButton.addAction(UIAction { [weak self] _ in self?.handlers.onCollections() }, for: .primaryActionTriggered)
        foldersButton.addAction(UIAction { [weak self] _ in self?.handlers.onBrowseFolders() }, for: .primaryActionTriggered)
        chips.onSelect = { [weak self] item in
            guard let filter = LibraryWatchFilter(rawValue: item.id) else { return }
            self?.handlers.onFilter(filter)
        }

        let controls = UIStackView(arrangedSubviews: [chips, genreButton, sortButton, filtersButton, UIView(), manageButton, collectionsButton, foldersButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = Theme.Space.s
        controls.setCustomSpacing(Theme.Space.m, after: chips)

        let stack = UIStackView(arrangedSubviews: [titleView, Self.scroller(for: controls)])
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
        ])
        installUpGuide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the controls in a row that scrolls sideways after the focus. An owner's library can hold more controls than the
    /// screen is wide, more so with a selected genre or a longer language, and a stack held to the header's width would
    /// squeeze its buttons to "…", push the last ones off the screen and strand the focus. The row is never narrower than the
    /// header, so while everything fits the spacer still pushes Manage, Collections and Folders to the trailing edge, and it
    /// does not clip, so a focused chip lifts in full and the row runs to the screen edges like a shelf.
    private static func scroller(for controls: UIStackView) -> UIScrollView {
        let scroller = UIScrollView()
        scroller.clipsToBounds = false
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(controls)
        let content = scroller.contentLayoutGuide
        let frame = scroller.frameLayoutGuide
        let fillsHeader = controls.widthAnchor.constraint(equalTo: frame.widthAnchor)
        fillsHeader.priority = .defaultLow
        NSLayoutConstraint.activate([
            fillsHeader,
            controls.topAnchor.constraint(equalTo: content.topAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.heightAnchor.constraint(equalTo: frame.heightAnchor),
            controls.widthAnchor.constraint(greaterThanOrEqualTo: frame.widthAnchor),
            frame.heightAnchor.constraint(equalToConstant: TVMetrics.Control.chipHeight),
        ])
        return scroller
    }

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
        filtersButton.isHidden = content.facets.isEmpty
        let filtering = content.facets.contains { $0.selectedKey != nil }
        TVButton.configure(menu: filtersMenu(content), title: String(localized: "Filters", comment: "Button that opens the menu of extra library filters"), style: .chip(selected: filtering), on: filtersButton)
        let manage = content.showsManage ? content.handlers.manageMenu() : nil
        manageButton.isHidden = manage == nil
        TVButton.configure(menu: manage ?? UIMenu(), title: ManageCopy.menuTitle, style: .chip(selected: false), on: manageButton)
    }

    private func filtersMenu(_ content: TVLibraryHeaderContent) -> UIMenu {
        UIMenu(title: String(localized: "Filters", comment: "Button that opens the menu of extra library filters"), children: content.facets.map { menu in
            let all = UIAction(title: menu.facet.allTitle, state: menu.selectedKey == nil ? .on : .off) { [weak self] _ in
                self?.handlers.onFacet(menu.facet, nil)
            }
            let choices = menu.choices.map { choice in
                UIAction(title: choice.title, state: choice.isSelected ? .on : .off) { [weak self] _ in
                    self?.handlers.onFacet(menu.facet, choice.key)
                }
            }
            return UIMenu(title: menu.facet.title, image: UIImage(systemName: menu.facet.symbol), children: [all] + choices)
        })
    }

    private func genreMenu(_ content: TVLibraryHeaderContent) -> UIMenu {
        let all = UIAction(title: String(localized: "All Genres"), state: content.isGenreSelected ? .off : .on) { [weak self] _ in
            self?.handlers.onGenre(nil)
        }
        let genres = content.genres.map { genre in
            UIAction(title: genre.title, state: genre.isSelected ? .on : .off) { [weak self] _ in
                self?.handlers.onGenre(genre.key)
            }
        }
        return UIMenu(title: String(localized: "Genre"), children: [all] + genres)
    }

    private func sortMenu(_ content: TVLibraryHeaderContent) -> UIMenu {
        UIMenu(title: String(localized: "Sort By"), children: content.sorts.map { sort in
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
