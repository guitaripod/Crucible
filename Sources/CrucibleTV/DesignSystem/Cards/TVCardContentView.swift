import CrucibleCore
import CrucibleDesign
import UIKit

struct TVCardConfiguration: UIContentConfiguration, Hashable {
    var item: TVCardItem
    var style: TVCardStyle

    func makeContentView() -> UIView & UIContentView {
        TVCardContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TVCardConfiguration {
        self
    }
}

/// The one card implementation. Artwork on top carries the system focus treatment; the caption sits
/// below and is pinned to the artwork's focused frame, so it slides down with the enlarged picture
/// instead of being covered by it.
final class TVCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private var style: TVCardStyle
    private let artwork: TVArtworkView
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressBar = ProgressBar()
    private let scrim = TVGradientView.bottomScrim()
    private let unwatchedDot = UIView()
    private let watchedBadge = UIImageView()
    private let badgeLabel = TVBadgeLabel()

    init(configuration: TVCardConfiguration) {
        self.configuration = configuration
        style = configuration.style
        artwork = TVArtworkView(
            kind: configuration.style.kind,
            nominalSize: configuration.style.artworkSize,
            shape: configuration.style.shape,
            placeholderSymbol: configuration.item.placeholderSymbol
        )
        super.init(frame: .zero)
        buildHierarchy()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy() {
        artwork.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)
        buildDecorations()

        let captionStack = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, subtitleLabel])
        captionStack.axis = .vertical
        captionStack.spacing = TVMetrics.Card.captionLabelSpacing
        captionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionStack)

        eyebrowLabel.font = TVCardTypography.eyebrow
        eyebrowLabel.textColor = Theme.Color.accentText
        eyebrowLabel.isHidden = !style.showsEyebrow
        titleLabel.font = TVCardTypography.title
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = style.titleLines
        subtitleLabel.font = TVCardTypography.subtitle
        subtitleLabel.textColor = Theme.Color.labelSecondary
        let alignment: NSTextAlignment = style.centersCaption ? .center : .natural
        [eyebrowLabel, titleLabel, subtitleLabel].forEach {
            $0.textAlignment = alignment
            $0.adjustsFontForContentSizeCategory = false
            $0.lineBreakMode = .byTruncatingTail
        }

        var constraints = [
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.widthAnchor.constraint(equalToConstant: style.artworkSize.width),
            artwork.heightAnchor.constraint(equalToConstant: style.artworkSize.height),
            artwork.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionStack.topAnchor.constraint(equalTo: artwork.focusedFrameGuide.bottomAnchor, constant: TVMetrics.Card.captionSpacing),
            captionStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if style.shape == .rounded {
            constraints.append(artwork.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func buildDecorations() {
        let overlay = artwork.overlayContentView
        let inset = TVMetrics.Card.badgeInset

        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isHidden = !style.scrimsArtwork
        overlay.addSubview(scrim)

        progressBar.style = .onArt
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(progressBar)

        unwatchedDot.backgroundColor = Theme.Color.accent
        unwatchedDot.layer.cornerRadius = TVMetrics.Card.dotDiameter / 2
        unwatchedDot.layer.borderWidth = 3
        unwatchedDot.layer.borderColor = UIColor.black.withAlphaComponent(0.5).cgColor
        unwatchedDot.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(unwatchedDot)

        watchedBadge.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .heavy)
        )
        watchedBadge.tintColor = Theme.Color.onArt
        watchedBadge.contentMode = .center
        watchedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        watchedBadge.layer.cornerRadius = TVMetrics.Card.checkDiameter / 2
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(watchedBadge)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            scrim.heightAnchor.constraint(equalTo: overlay.heightAnchor, multiplier: 0.4),

            progressBar.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: inset),
            progressBar.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -inset),
            progressBar.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -inset),
            progressBar.heightAnchor.constraint(equalToConstant: Theme.Metric.progressBarThickness),

            unwatchedDot.topAnchor.constraint(equalTo: overlay.topAnchor, constant: inset),
            unwatchedDot.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -inset),
            unwatchedDot.widthAnchor.constraint(equalToConstant: TVMetrics.Card.dotDiameter),
            unwatchedDot.heightAnchor.constraint(equalToConstant: TVMetrics.Card.dotDiameter),

            watchedBadge.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -inset),
            watchedBadge.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -inset),
            watchedBadge.widthAnchor.constraint(equalToConstant: TVMetrics.Card.checkDiameter),
            watchedBadge.heightAnchor.constraint(equalToConstant: TVMetrics.Card.checkDiameter),

            badgeLabel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: inset),
            badgeLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: inset),
            badgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -inset),
        ])
    }

    /// `text` with the part the search query matched in the accent colour; plain when there is no query.
    private func highlighted(_ text: String, query: String?, font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard let query, !query.isEmpty else { return result }
        for range in SearchHighlight.matchRanges(of: query, in: text) {
            result.addAttribute(.foregroundColor, value: Theme.Color.accentText, range: range)
        }
        return result
    }

    private func apply() {
        guard let configuration = configuration as? TVCardConfiguration else { return }
        let item = configuration.item
        eyebrowLabel.text = item.eyebrow?.uppercased()
        eyebrowLabel.isHidden = !style.showsEyebrow
        titleLabel.attributedText = highlighted(item.title, query: item.highlight, font: TVCardTypography.title, color: Theme.Color.label)
        subtitleLabel.attributedText = highlighted(
            item.subtitle ?? "", query: item.highlight, font: TVCardTypography.subtitle, color: Theme.Color.labelSecondary
        )
        subtitleLabel.isHidden = (item.subtitle ?? "").isEmpty

        let showsProgress = item.hasProgress
        progressBar.isHidden = !showsProgress
        if let progress = item.progress, showsProgress { progressBar.progress = progress }
        unwatchedDot.isHidden = !(item.isUnwatched && !showsProgress && !item.isWatched)
        watchedBadge.isHidden = !item.isWatched || showsProgress
        badgeLabel.text = item.badgeText
        badgeLabel.isHidden = (item.badgeText ?? "").isEmpty

        artwork.setArtwork(path: item.artworkPath, placeholderSymbol: item.placeholderSymbol)
    }
}
