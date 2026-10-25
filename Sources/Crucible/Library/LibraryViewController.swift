import CrucibleCore
import CrucibleDesign
import UIKit

final class LibraryViewController: UIViewController, LibraryGridHosting {
    private struct Library {
        let title: String
        let kind: LibraryGridKind
        let grid: LibraryGridViewController
    }

    private let api: APIClient
    private let pinnedSectionID: String?
    private var sections: [LibrarySection] = []
    private var libraries: [Library] = []
    private var currentIndex = 0
    private var currentChild: LibraryGridViewController?
    private var loadTask: Task<Void, Never>?
    private var preloaded: PlexMediaContainer?

    private lazy var optionsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: LibraryGridOptions.optionsImage(filtering: false), menu: nil)
        item.accessibilityLabel = "Sort and Filter"
        return item
    }()

    private lazy var gridSizeItem = LibraryGridSizeMenu.barButtonItem { [weak self] in
        self?.currentChild?.gridWidth ?? 0
    } onChange: { [weak self] in
        self?.reloadGrids()
    }

    private func reloadGrids() {
        libraries.forEach { $0.grid.reloadGridLayout() }
    }

    /// Asks the host to show another library; set for a screen pinned to one library, whose title menu then switches libraries.
    var onSelectLibrary: ((String) -> Void)?

    /// `pinnedSectionID` shows that library alone, for a sidebar entry; nil shows every library behind the title menu.
    init(api: APIClient, preloaded: PlexMediaContainer? = nil, pinnedSectionID: String? = nil) {
        self.api = api
        self.preloaded = preloaded
        self.pinnedSectionID = pinnedSectionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = Theme.Color.canvas
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        if let preloaded {
            self.preloaded = nil
            install(sections: preloaded)
        } else {
            loadSections()
        }
    }

    func libraryGridDidUpdateOptions(_ grid: LibraryGridViewController) {
        guard grid === currentChild else { return }
        optionsItem.menu = grid.optionsMenu()
        optionsItem.image = LibraryGridOptions.optionsImage(filtering: grid.isFiltering)
    }

    private func loadSections() {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sections)
                guard !Task.isCancelled else { return }
                install(sections: container)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Library sections fetch failed: \(error.localizedDescription)", .networking)
                showErrorState(error)
            }
        }
    }

    private func install(sections container: PlexMediaContainer) {
        contentUnavailableConfiguration = nil
        sections = LibrarySection.sections(in: container)
        let shown = pinnedSectionID.map { id in sections.filter { $0.id == id } } ?? sections
        libraries = shown.map { section in
            switch section.kind {
            case .movie:
                return Library(title: section.title, kind: .movie, grid: MovieGridViewController(api: api, sectionId: section.id))
            case .show:
                return Library(title: section.title, kind: .show, grid: ShowGridViewController(api: api, sectionId: section.id))
            }
        }
        currentIndex = 0
        AppLogger.info("Library sections loaded: \(libraries.map(\.title).joined(separator: ", "))", .ui)
        configureNavigation()
        if let first = libraries.first {
            showChild(first.grid)
        } else {
            showEmptyState()
        }
    }

    private func showEmptyState() {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "rectangle.stack")
        config.text = "No Libraries"
        config.secondaryText = "Add a movie or TV show library to your Plex server to browse it here."
        contentUnavailableConfiguration = config
    }

    private func showErrorState(_ error: Error) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = "Couldn’t Load Libraries"
        config.secondaryText = ConnectionError.message(for: error)
        config.button = ThemeButton.primaryConfiguration(title: "Retry")
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.loadSections()
        }
        contentUnavailableConfiguration = config
    }

    /// The library name is the large title and doubles as the switcher: the system title menu lists
    /// every library plus folder browsing.
    private func configureNavigation() {
        title = libraries.indices.contains(currentIndex) ? libraries[currentIndex].title : "Library"
        guard !libraries.isEmpty else {
            navigationItem.titleMenuProvider = nil
            navigationItem.rightBarButtonItems = nil
            return
        }
        navigationItem.titleMenuProvider = { [weak self] _ in
            self?.libraryMenu()
        }
        navigationItem.rightBarButtonItems = [optionsItem, gridSizeItem]
    }

    private func libraryMenu() -> UIMenu {
        let switcher = sections.enumerated().map { index, section in
            UIAction(
                title: section.title,
                image: UIImage(systemName: section.kind == .movie ? "film" : "tv"),
                state: isShowing(section, at: index) ? .on : .off
            ) { [weak self] _ in
                self?.selectLibrary(section, at: index)
            }
        }
        let folders = UIAction(title: "Browse Folders", image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.currentChild?.openFolderBrowser()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: switcher),
            UIMenu(options: .displayInline, children: [folders]),
        ])
    }

    private func isShowing(_ section: LibrarySection, at index: Int) -> Bool {
        pinnedSectionID.map { $0 == section.id } ?? (index == currentIndex)
    }

    private func selectLibrary(_ section: LibrarySection, at index: Int) {
        guard !isShowing(section, at: index) else { return }
        guard pinnedSectionID == nil else {
            onSelectLibrary?(section.id)
            return
        }
        selectLibrary(index)
    }

    private func selectLibrary(_ index: Int) {
        guard libraries.indices.contains(index), index != currentIndex else { return }
        AppLogger.info("Library switch -> \(libraries[index].title)", .ui)
        Haptics.selection()
        currentIndex = index
        configureNavigation()
        showChild(libraries[index].grid)
    }

    private func showChild(_ child: LibraryGridViewController) {
        let old = currentChild
        currentChild = child
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setContentScrollView(child.collectionView, for: [.top, .bottom])
        libraryGridDidUpdateOptions(child)

        guard let old, old !== child else {
            view.addSubview(child.view)
            child.didMove(toParent: self)
            return
        }
        old.willMove(toParent: nil)
        transition(from: old, to: child, duration: 0.2, options: .transitionCrossDissolve) {
            child.view.frame = self.view.bounds
        } completion: { _ in
            old.removeFromParent()
            child.didMove(toParent: self)
        }
    }
}

extension LibraryViewController: CommandHandling {
    func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .refresh: return currentChild != nil
        case .largerPosters: return currentChild != nil && Preferences.libraryColumns == 3
        case .smallerPosters: return currentChild != nil && Preferences.libraryColumns == 2
        default: return false
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .refresh: currentChild?.refresh()
        case .largerPosters: if LibraryGridSizeMenu.set(2) { reloadGrids() }
        case .smallerPosters: if LibraryGridSizeMenu.set(3) { reloadGrids() }
        default: break
        }
    }
}
