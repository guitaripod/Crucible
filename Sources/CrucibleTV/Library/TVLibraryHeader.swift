import CrucibleCore
import CrucibleDesign
import UIKit

/// What the header above a library grid shows: the title and count, the watch-filter chips, the
/// Genre and Sort menus and the Browse Folders button. Equality ignores the handlers so a redraw
/// only happens when the visible content changed.
struct TVLibraryHeaderConfiguration: UIContentConfiguration, Hashable {
    struct Chip: Hashable {
        var filter: LibraryWatchFilter
        var isSelected: Bool
    }

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
    var chips: [Chip]
    var genreTitle: String
    var isGenreSelected: Bool
    var genres: [Choice]
    var sortTitle: String
    var sorts: [Choice]
    var handlers = Handlers()

    func makeContentView() -> UIView & UIContentView {
        TVLibraryHeaderContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TVLibraryHeaderConfiguration {
        self
    }
}

/// The header block that scrolls above the grid. The buttons are updated in place, so a filter
/// change never rebuilds the view the focus is sitting on.
final class TVLibraryHeaderContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private var chipButtons: [LibraryWatchFilter: UIButton] = [:]
    private let genreButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)
    private let foldersButton = UIButton(type: .system)
    private let upGuide = UIFocusGuide()
    private var handlers = TVLibraryHeaderConfiguration.Handlers()

    init(configuration: TVLibraryHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        buildHierarchy()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The height of the block for the current type sizes.
    @MainActor
    static var height: CGFloat {
        ceil(titleFont.lineHeight + countFont.lineHeight + Theme.Space.l + TVMetrics.Control.chipHeight)
    }

    private static var titleFont: UIFont { Theme.Font.title2 }
    private static var countFont: UIFont { Theme.Font.callout }

    private func buildHierarchy() {
        clipsToBounds = false
        titleLabel.font = Self.titleFont
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header
        countLabel.font = Self.countFont
        countLabel.textColor = Theme.Color.labelSecondary

        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = Theme.Space.s
        for filter in LibraryWatchFilter.allCases {
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "tv.library.chip.\(filter.rawValue)"
            button.addAction(UIAction { [weak self] _ in self?.handlers.onFilter(filter) }, for: .primaryActionTriggered)
            chipButtons[filter] = button
            chips.addArrangedSubview(button)
        }

        genreButton.accessibilityIdentifier = "tv.library.genre"
        sortButton.accessibilityIdentifier = "tv.library.sort"
        foldersButton.accessibilityIdentifier = "tv.library.folders"
        foldersButton.configuration = TVButton.configuration(.chip(selected: false), title: "Browse Folders", symbol: "folder")
        foldersButton.accessibilityLabel = "Browse Folders"
        foldersButton.addAction(UIAction { [weak self] _ in self?.handlers.onBrowseFolders() }, for: .primaryActionTriggered)

        let controls = UIStackView(arrangedSubviews: [chips, genreButton, sortButton, UIView(), foldersButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = Theme.Space.m
        controls.setCustomSpacing(Theme.Space.l, after: chips)

        let stack = UIStackView(arrangedSubviews: [titleLabel, countLabel, controls])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.setCustomSpacing(Theme.Space.l, after: countLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.heightAnchor.constraint(equalToConstant: TVMetrics.Control.chipHeight),
        ])
        installUpGuide()
    }

    /// Pressing Up from the first poster of a row would otherwise skip the chips and jump to the tab bar;
    /// a guide just under the header sends it to the selected chip instead.
    private func installUpGuide() {
        addLayoutGuide(upGuide)
        NSLayoutConstraint.activate([
            upGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            upGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            upGuide.topAnchor.constraint(equalTo: bottomAnchor, constant: Theme.Space.xs),
            upGuide.heightAnchor.constraint(equalToConstant: Theme.Space.m),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? TVLibraryHeaderConfiguration else { return }
        handlers = configuration.handlers
        titleLabel.text = configuration.title
        countLabel.text = configuration.count
        countLabel.isHidden = (configuration.count ?? "").isEmpty

        let selected = configuration.chips.first { $0.isSelected }?.filter ?? .all
        upGuide.preferredFocusEnvironments = chipButtons[selected].map { [$0] } ?? []

        for chip in configuration.chips {
            guard let button = chipButtons[chip.filter] else { continue }
            button.configuration = TVButton.configuration(.chip(selected: chip.isSelected), title: chip.filter.title)
            button.accessibilityLabel = chip.filter.title
            button.accessibilityTraits = chip.isSelected ? [.button, .selected] : .button
        }

        genreButton.isHidden = configuration.genres.isEmpty
        apply(
            menuButton: genreButton,
            title: configuration.genreTitle,
            selected: configuration.isGenreSelected,
            menu: genreMenu(configuration)
        )
        apply(menuButton: sortButton, title: configuration.sortTitle, selected: false, menu: sortMenu(configuration))
    }

    private func apply(menuButton button: UIButton, title: String, selected: Bool, menu: UIMenu) {
        var buttonConfiguration = TVButton.configuration(.chip(selected: selected), title: title)
        buttonConfiguration.image = UIImage(systemName: "chevron.down")
        buttonConfiguration.imagePlacement = .trailing
        buttonConfiguration.imagePadding = Theme.Space.xs
        buttonConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            font: Theme.Font.scaled(.body, 29, .semibold, maximum: 40),
            scale: .small
        )
        button.configuration = buttonConfiguration
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = title
    }

    private func genreMenu(_ configuration: TVLibraryHeaderConfiguration) -> UIMenu {
        let all = UIAction(title: "All Genres", state: configuration.isGenreSelected ? .off : .on) { [weak self] _ in
            self?.handlers.onGenre(nil)
        }
        let genres = configuration.genres.map { genre in
            UIAction(title: genre.title, state: genre.isSelected ? .on : .off) { [weak self] _ in
                self?.handlers.onGenre(genre.key)
            }
        }
        return UIMenu(title: "Genre", children: [all] + genres)
    }

    private func sortMenu(_ configuration: TVLibraryHeaderConfiguration) -> UIMenu {
        UIMenu(title: "Sort By", children: configuration.sorts.map { sort in
            UIAction(title: sort.title, state: sort.isSelected ? .on : .off) { [weak self] _ in
                self?.handlers.onSort(sort.key)
            }
        })
    }
}

/// Hosts `TVLibraryHeaderContentView`. The cell itself is never focused; the buttons inside are.
final class TVLibraryHeaderCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }
}
