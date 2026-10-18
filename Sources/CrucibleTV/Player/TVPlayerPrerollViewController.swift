import CrucibleDesign
import UIKit

/// What the viewer sees from pressing Play until the first frame: a dark screen with the artwork, the
/// title and a spinner, faded in together once the artwork is ready so nothing pops in piece by piece. It is its own full-screen controller because the system player draws its transport bar
/// over anything placed inside it, even before a player is attached. Menu closes it, which cancels
/// the playback that is starting.
@MainActor
final class TVPlayerPrerollViewController: UIViewController {
    var onClose: (() -> Void)?
    private var isClosingProgrammatically = false

    private static let posterHeight: CGFloat = 360
    private static let posterWait: TimeInterval = 0.4

    private let spinner = UIActivityIndicatorView(style: .large)
    private let posterView = UIImageView()
    private let content = UIStackView()
    private var loadTask: Task<Void, Never>?
    private var hasAppeared = false
    private var appearWaiters: [CheckedContinuation<Void, Never>] = []
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let headline: (title: String, subtitle: String?)
    private let posterPath: String?

    init(title: String, subtitle: String?, posterPath: String?) {
        headline = (title, subtitle)
        self.posterPath = posterPath
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "player.preroll"
        view.accessibilityLabel = [headline.title, headline.subtitle].compactMap { $0 }.joined(separator: ", ")
        build()
        revealContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        spinner.startAnimating()
        hasAppeared = true
        resumeAppearWaiters()
    }

    deinit { loadTask?.cancel() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resumeAppearWaiters()
        guard isBeingDismissed || presentingViewController == nil, !isClosingProgrammatically else { return }
        onClose?()
    }

    /// Returns once the screen is fully on screen, so a presentation started from it never races its own.
    func waitUntilShown() async {
        guard !hasAppeared else { return }
        await withCheckedContinuation { appearWaiters.append($0) }
    }

    private func resumeAppearWaiters() {
        let waiters = appearWaiters
        appearWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Lets the screen go away without reporting a viewer-initiated close.
    func suppressCloseReport() {
        isClosingProgrammatically = true
    }

    /// Removes the screen without reporting a viewer-initiated close.
    func close(animated: Bool) {
        isClosingProgrammatically = true
        spinner.stopAnimating()
        loadTask?.cancel()
        resumeAppearWaiters()
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

        posterView.isHidden = true
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.layer.cornerCurve = .continuous
        posterView.layer.cornerRadius = TVMetrics.Card.cornerRadius
        posterView.heightAnchor.constraint(equalToConstant: Self.posterHeight).isActive = true

        [posterView, titleLabel, subtitleLabel, spinner].forEach(content.addArrangedSubview)
        content.axis = .vertical
        content.alignment = .center
        content.spacing = Theme.Space.m
        content.setCustomSpacing(Theme.Space.l, after: posterView)
        content.setCustomSpacing(Theme.Space.l, after: subtitleLabel)
        content.alpha = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: TVMetrics.gutter * 2),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -TVMetrics.gutter * 2),
        ])
    }

    /// Fades the content in once the artwork is in place. The picture is normally cached already,
    /// because the viewer was just looking at it; a slow or missing one only delays the fade briefly.
    private func revealContent() {
        loadTask = Task { [weak self, posterPath] in
            let image = await Self.loadPoster(path: posterPath)
            guard !Task.isCancelled, let self else { return }
            if let image { show(poster: image) }
            fadeInContent()
        }
    }

    /// The poster, or nil when it is not there within `posterWait`: the pre-roll never holds the
    /// screen black for a slow picture.
    private static func loadPoster(path: String?) async -> UIImage? {
        guard let path else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let race = PosterRace(continuation)
            Task { race.finish(await TVPlayerMetadata.loadPoster(path: path)) }
            Task {
                try? await Task.sleep(for: .seconds(posterWait))
                race.finish(nil)
            }
        }
    }

    private func show(poster image: UIImage) {
        posterView.image = image
        let aspect = image.size.width / max(image.size.height, 1)
        posterView.widthAnchor.constraint(equalTo: posterView.heightAnchor, multiplier: aspect).isActive = true
        posterView.isHidden = false
    }

    private func fadeInContent() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            content.alpha = 1
            return
        }
        UIView.animate(withDuration: TVMetrics.Duration.backdropFade, delay: 0, options: .curveEaseOut) {
            self.content.alpha = 1
        }
    }
}

/// Delivers the first of two racing answers to a continuation and drops the second.
@MainActor
private final class PosterRace {
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(_ continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func finish(_ image: UIImage?) {
        continuation?.resume(returning: image)
        continuation = nil
    }
}
