import UIKit

final class LibraryViewController: UIViewController {
    private let api: APIClient
    private var titles: [String] = []
    private var sectionVCs: [UIViewController] = []
    private var currentIndex = 0
    private var currentChild: UIViewController?
    private var loadTask: Task<Void, Never>?
    private let titleButton = UIButton(configuration: .plain())

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemBackground
        titleButton.showsMenuAsPrimaryAction = true
        loadSections()
    }

    private func loadSections() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sections)
                guard !Task.isCancelled else { return }
                let dirs = container.Directory ?? []

                var titles = [String]()
                var vcs = [UIViewController]()

                for dir in dirs {
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

                if let first = vcs.first {
                    showChild(first)
                }
            } catch {}
        }
    }

    private func configureNavTitle() {
        guard titles.count > 1 else {
            navigationItem.titleView = nil
            title = titles.first ?? "Library"
            return
        }
        updateTitleButton()
        navigationItem.titleView = titleButton
    }

    private func updateTitleButton() {
        var config = UIButton.Configuration.plain()
        config.title = titles[currentIndex]
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(scale: .small))
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.baseForegroundColor = .label
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 17, weight: .semibold)
            return outgoing
        }
        titleButton.configuration = config
        titleButton.menu = UIMenu(children: titles.enumerated().map { index, name in
            UIAction(title: name, state: index == currentIndex ? .on : .off) { [weak self] _ in
                self?.selectLibrary(index)
            }
        })
        titleButton.sizeToFit()
    }

    private func selectLibrary(_ index: Int) {
        guard index >= 0, index < sectionVCs.count, index != currentIndex else { return }
        currentIndex = index
        updateTitleButton()
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
