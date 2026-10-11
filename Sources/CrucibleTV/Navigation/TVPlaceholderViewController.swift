import CrucibleDesign
import UIKit

/// The body every seam in `TVScreens` returns until its feature lands: the screen's name,
/// centred on the canvas.
final class TVPlaceholderViewController: UIViewController {
    private let titleLabel = UILabel()

    init(name: String) {
        super.init(nibName: nil, bundle: nil)
        title = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas

        titleLabel.text = title
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "placeholder.title"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
        ])
    }
}
