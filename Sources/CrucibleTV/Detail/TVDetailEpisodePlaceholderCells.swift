import CrucibleDesign
import UIKit

/// A card-shaped stand-in for an episode while its season loads. It is static, so nothing keeps
/// animating while the screen waits.
final class TVDetailEpisodePlaceholderCell: UICollectionViewCell {
    private static let captionBars: [(width: CGFloat, height: CGFloat)] = [(120, 20), (300, 28), (180, 22)]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        isAccessibilityElement = false

        let artwork = Self.block(size: TVCardStyle.episode.artworkSize, radius: TVMetrics.Card.cornerRadius)
        let captions = Self.captionBars.map { Self.block(size: CGSize(width: $0.width, height: $0.height), radius: Theme.Radius.xs) }
        let stack = UIStackView(arrangedSubviews: [artwork] + captions)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = TVMetrics.Card.captionLabelSpacing * 3
        stack.setCustomSpacing(TVMetrics.Card.captionSpacing, after: artwork)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    func configure(index: Int) {
        isAccessibilityElement = index == 0
        accessibilityLabel = "Loading episodes"
        accessibilityIdentifier = "detail.episodes.loading"
    }

    private static func block(size: CGSize, radius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = Theme.Color.surfaceRaised
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return view
    }
}

/// What the episode shelf shows when the selected season could not be fetched: the reason and a
/// Retry button, so a failure never reads as an empty season.
final class TVDetailEpisodesFailedCell: UICollectionViewCell {
    private let message = UILabel()
    private let retryButton = UIButton(type: .system)
    private var actionIdentifier: UIAction.Identifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false

        message.font = Theme.Font.callout
        message.textColor = Theme.Color.labelSecondary
        message.numberOfLines = 3
        message.text = "Couldn\u{2019}t load this season."
        message.accessibilityIdentifier = "detail.episodes.failed"

        retryButton.configuration = TVButton.configuration(.glass, title: "Retry")
        retryButton.accessibilityIdentifier = "detail.episodes.retry"
        retryButton.accessibilityLabel = "Retry loading episodes"

        let stack = UIStackView(arrangedSubviews: [message, retryButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [retryButton] }

    static func registration(
        onRetry: @escaping @MainActor () -> Void
    ) -> UICollectionView.CellRegistration<TVDetailEpisodesFailedCell, Int> {
        UICollectionView.CellRegistration<TVDetailEpisodesFailedCell, Int> { cell, _, _ in
            cell.configure(onRetry: onRetry)
        }
    }

    private func configure(onRetry: @escaping @MainActor () -> Void) {
        if let identifier = actionIdentifier {
            retryButton.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
        }
        let action = UIAction { _ in onRetry() }
        actionIdentifier = action.identifier
        retryButton.addAction(action, for: .primaryActionTriggered)
    }
}
