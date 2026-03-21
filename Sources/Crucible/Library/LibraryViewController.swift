import UIKit

final class LibraryViewController: UIViewController {
    private let api: APIClient
    private var segmentedControl: UISegmentedControl!
    private var sectionVCs: [UIViewController] = []
    private var currentChild: UIViewController?
    private var loadTask: Task<Void, Never>?

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
                        titles.append(dir.title)
                        vcs.append(MovieGridViewController(api: api, sectionId: dir.key))
                    case "show":
                        titles.append(dir.title)
                        vcs.append(ShowGridViewController(api: api, sectionId: dir.key))
                    default:
                        continue
                    }
                }

                sectionVCs = vcs

                if titles.count > 1 {
                    segmentedControl = UISegmentedControl(items: titles)
                    segmentedControl.selectedSegmentIndex = 0
                    segmentedControl.addAction(UIAction { [unowned self] _ in
                        switchSegment()
                    }, for: .valueChanged)
                    navigationItem.titleView = segmentedControl
                }

                if let first = vcs.first {
                    showChild(first)
                }
            } catch {}
        }
    }

    private func switchSegment() {
        let idx = segmentedControl.selectedSegmentIndex
        guard idx >= 0, idx < sectionVCs.count else { return }
        let target = sectionVCs[idx]
        guard target !== currentChild else { return }
        showChild(target)
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
