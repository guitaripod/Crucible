import CrucibleCore
import CrucibleDesign
import UIKit

/// The best match for the query: its poster, what it is, and the two things to do with it. The
/// card data is the design system's `TVCardItem` (poster, title, type line, highlighted query); the
/// view itself never takes focus, the Play and open buttons do. Hosted in a `TVHostCell`.
final class TVSearchTopResultView: UIView {
    private static let posterSize = CGSize(width: 200, height: 300)

    private let playButton: UIButton?
    private let openButton: UIButton

    init(card: TVCardItem, playTitle: String?, openTitle: String, onPlay: @escaping @MainActor () -> Void, onOpen: @escaping @MainActor () -> Void) {
        playButton = playTitle.map { title in
            let button = TVButton.make(.primary, title: title, symbol: "play.fill", action: onPlay)
            button.accessibilityLabel = "\(title) \(card.title)"
            button.accessibilityIdentifier = "search.top.play"
            return button
        }
        openButton = TVButton.make(.glass, title: openTitle, action: onOpen)
        super.init(frame: .zero)
        openButton.accessibilityLabel = "\(openTitle), \(card.title)"
        openButton.accessibilityIdentifier = "search.top.open"
        buildHierarchy(card: card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [playButton ?? openButton]
    }

    private func buildHierarchy(card: TVCardItem) {
        let artwork = TVArtworkView(kind: .poster, nominalSize: Self.posterSize, placeholderSymbol: card.placeholderSymbol)
        artwork.setArtwork(path: card.artworkPath, placeholderSymbol: card.placeholderSymbol)
        artwork.translatesAutoresizingMaskIntoConstraints = false

        let eyebrow = UILabel()
        eyebrow.text = SearchCopy.topResultEyebrow.uppercased()
        eyebrow.font = TVFont.eyebrow
        eyebrow.textColor = Theme.Color.accentText
        let title = UILabel()
        title.attributedText = .highlighting(card.title, query: card.highlight, font: TVFont.screenTitle, color: Theme.Color.label)
        title.numberOfLines = 2
        let meta = UILabel()
        meta.text = card.subtitle
        meta.font = TVFont.screenSummary
        meta.textColor = Theme.Color.labelSecondary

        let buttons = UIStackView(arrangedSubviews: [playButton, openButton].compactMap { $0 })
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.m

        let text = UIStackView(arrangedSubviews: [eyebrow, title, meta, buttons])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.m, after: meta)
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(artwork)
        addSubview(text)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.widthAnchor.constraint(equalToConstant: Self.posterSize.width),
            artwork.heightAnchor.constraint(equalToConstant: Self.posterSize.height),
            text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: TVMetrics.gutter),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
        ])
    }
}
