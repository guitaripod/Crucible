import UIKit

final class LibraryViewController: UIViewController {
    private let api: APIClient
    private let segmentedControl: UISegmentedControl
    private var movieGrid: MovieGridViewController
    private var showGrid: ShowGridViewController
    private var currentChild: UIViewController?

    init(api: APIClient) {
        self.api = api
        self.movieGrid = MovieGridViewController(api: api)
        self.showGrid = ShowGridViewController(api: api)
        self.segmentedControl = UISegmentedControl(items: ["Movies", "Shows"])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemBackground

        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addAction(UIAction { [unowned self] _ in
            switchSegment()
        }, for: .valueChanged)
        navigationItem.titleView = segmentedControl

        showChild(movieGrid)
    }

    private func switchSegment() {
        let target = segmentedControl.selectedSegmentIndex == 0 ? movieGrid : showGrid
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
