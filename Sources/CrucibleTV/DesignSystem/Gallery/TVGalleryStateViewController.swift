#if DEBUG
import CrucibleDesign
import UIKit

/// One state view at full-screen size: `CRUCIBLE_GALLERY=state-loading|state-empty|state-error`.
/// The loading screen also shows a skeleton shelf, as a library screen does while its first page loads.
final class TVGalleryStateViewController: UIViewController {
    private let mode: String
    private let stateView = TVStateView()

    init(mode: String) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [stateView] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let bottom = stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        bottom.priority = UILayoutPriority(750)
        bottom.isActive = true
        switch mode {
        case "state-empty":
            stateView.show(.empty(
                title: "No Matches",
                message: "Nothing in Movies fits these filters.",
                symbol: "line.3.horizontal.decrease.circle",
                action: TVStateView.Action(title: "Clear Filters") {}
            ))
        case "state-error":
            stateView.show(.error(
                title: "Couldn't Load Library",
                message: "Marcus-PC didn't answer. Check the connection and try again.",
                retryTitle: "Try Again"
            ) {})
        default:
            stateView.show(.loading(title: "Loading Movies"))
            addSkeleton()
        }
    }

    private func addSkeleton() {
        let skeleton = TVSkeletonShelfView()
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60),
            stateView.bottomAnchor.constraint(equalTo: skeleton.topAnchor),
        ])
    }
}
#endif
