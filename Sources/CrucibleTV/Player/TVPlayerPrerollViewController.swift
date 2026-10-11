import CrucibleDesign
import UIKit

/// What the viewer sees from pressing Play until the first frame: a dark screen with the title and a
/// spinner. It is its own full-screen controller because the system player draws its transport bar
/// over anything placed inside it, even before a player is attached. Menu closes it, which cancels
/// the playback that is starting.
@MainActor
final class TVPlayerPrerollViewController: UIViewController {
    var onClose: (() -> Void)?
    private var isClosingProgrammatically = false

    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let headline: (title: String, subtitle: String?)

    init(title: String, subtitle: String?) {
        headline = (title, subtitle)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "player.preroll"
        view.accessibilityLabel = [headline.title, headline.subtitle].compactMap { $0 }.joined(separator: ", ")
        build()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        spinner.startAnimating()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil, !isClosingProgrammatically else { return }
        onClose?()
    }

    /// Lets the screen go away without reporting a viewer-initiated close.
    func suppressCloseReport() {
        isClosingProgrammatically = true
    }

    /// Removes the screen without reporting a viewer-initiated close.
    func close(animated: Bool) {
        isClosingProgrammatically = true
        spinner.stopAnimating()
        presentingViewController?.dismiss(animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func build() {
        spinner.color = Theme.Color.onArt
        titleLabel.text = headline.title
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        subtitleLabel.text = headline.subtitle
        subtitleLabel.isHidden = headline.subtitle == nil
        subtitleLabel.font = Theme.Font.callout
        subtitleLabel.textColor = Theme.Color.onArtSecondary
        subtitleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.l, after: spinner)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: TVMetrics.gutter * 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -TVMetrics.gutter * 2),
        ])
    }
}
