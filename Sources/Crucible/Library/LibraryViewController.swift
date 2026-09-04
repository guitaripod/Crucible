import UIKit

/// Implemented by `LibraryViewController` so embedded grid view controllers can publish their
/// options state into the shared bottom action bar.
@MainActor
struct LibraryActionBarConfig {
    let optionsMenu: UIMenu
    let optionsIcon: UIImage?
    let onBrowseFolders: () -> Void
}

@MainActor
protocol LibrarySectionsProviding: AnyObject {
    func updateActionBar(_ config: LibraryActionBarConfig)
}

final class LibraryViewController: UIViewController, LibrarySectionsProviding {
    private let api: APIClient
    private var titles: [String] = []
    private var sectionVCs: [UIViewController] = []
    private var currentIndex = 0
    private var currentChild: UIViewController?
    private var loadTask: Task<Void, Never>?
    private let actionBar = LibraryActionBarView()
    private var preloaded: PlexMediaContainer?

    init(api: APIClient, preloaded: PlexMediaContainer? = nil) {
        self.api = api
        self.preloaded = preloaded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemBackground
        view.addSubview(actionBar)
        actionBar.isHidden = true
        if let preloaded {
            self.preloaded = nil
            install(sections: preloaded)
        } else {
            loadSections()
        }
    }

    func updateActionBar(_ config: LibraryActionBarConfig) {
        actionBar.setOptions(menu: config.optionsMenu, icon: config.optionsIcon)
        actionBar.setFolderAction(config.onBrowseFolders)
        actionBar.isHidden = currentChild == nil
        layoutActionBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutActionBar()
    }


    private func layoutActionBar() {
        guard !actionBar.isHidden else {
            if additionalSafeAreaInsets.bottom != 0 {
                additionalSafeAreaInsets.bottom = 0
            }
            return
        }
        let systemBottom = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        let contentBottom = view.bounds.height - systemBottom
        let tabBarTop: CGFloat
        if let tabBar = tabBarController?.tabBar {
            tabBarTop = view.convert(tabBar.bounds, from: tabBar).minY
        } else {
            tabBarTop = view.bounds.height
        }
        let width = min(view.bounds.width - 32, 540)
        actionBar.frame = CGRect(
            x: (view.bounds.width - width) / 2,
            y: tabBarTop - 8 - LibraryActionBarView.height,
            width: width,
            height: LibraryActionBarView.height
        )
        view.bringSubviewToFront(actionBar)
        let targetInset = max(0, actionBar.frame.minY - contentBottom + 8)
        if additionalSafeAreaInsets.bottom != targetInset {
            additionalSafeAreaInsets.bottom = targetInset
        }
    }

    private func loadSections() {
        contentUnavailableConfiguration = nil
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
        var titles = [String]()
        var vcs = [UIViewController]()

        for dir in container.Directory ?? [] {
            switch dir.type {
            case "movie":
                guard let key = dir.key else { continue }
                titles.append(dir.title ?? "Movies")
                vcs.append(MovieGridViewController(api: api, sectionId: key))
            case "show":
                guard let key = dir.key else { continue }
                titles.append(dir.title ?? "Shows")
                vcs.append(ShowGridViewController(api: api, sectionId: key))
            default:
                continue
            }
        }

        self.titles = titles
        self.sectionVCs = vcs
        self.currentIndex = 0
        configureNavTitle()
        AppLogger.info("Library sections loaded: \(titles.joined(separator: ", "))", .ui)

        if let first = vcs.first {
            showChild(first)
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
        config.text = "Couldn't Load Libraries"
        config.secondaryText = ConnectionError.message(for: error)
        var button = UIButton.Configuration.filled()
        button.title = "Retry"
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self else { return }
            contentUnavailableConfiguration = nil
            loadSections()
        }
        contentUnavailableConfiguration = config
    }

    private func configureNavTitle() {
        title = titles.indices.contains(currentIndex) ? titles[currentIndex] : "Library"
        updateSwitcherButton()
        AppLogger.info("Library nav: \(titles.count) libraries", .ui)
    }

    private func updateSwitcherButton() {
        let name = titles.indices.contains(currentIndex) ? titles[currentIndex] : "Library"
        actionBar.setSwitcher(title: name, menu: UIMenu(children: titles.enumerated().map { index, library in
            UIAction(title: library, state: index == currentIndex ? .on : .off) { [weak self] _ in
                self?.selectLibrary(index)
            }
        }))
    }

    private func selectLibrary(_ index: Int) {
        guard index >= 0, index < sectionVCs.count, index != currentIndex else { return }
        AppLogger.info("Library switch -> \(titles[index])", .ui)
        currentIndex = index
        configureNavTitle()
        showChild(sectionVCs[index])
    }

    private func showChild(_ child: UIViewController) {
        let old = currentChild

        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if let old {
            old.willMove(toParent: nil)
            transition(from: old, to: child, duration: 0.2, options: .transitionCrossDissolve) {
                child.view.frame = self.view.bounds
            } completion: { _ in
                old.removeFromParent()
                child.didMove(toParent: self)
            }
        } else {
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }

        currentChild = child
    }
}
