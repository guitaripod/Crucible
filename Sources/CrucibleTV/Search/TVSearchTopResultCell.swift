import CrucibleCore
import CrucibleDesign
import UIKit

struct TVSearchTopResultConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var placeholderSymbol = "film"
    var title = ""
    var meta = ""
    var query: String?
    var playTitle: String?
    var openTitle = ""
    var onPlay: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?

    static func == (lhs: TVSearchTopResultConfiguration, rhs: TVSearchTopResultConfiguration) -> Bool {
        lhs.posterPath == rhs.posterPath && lhs.placeholderSymbol == rhs.placeholderSymbol && lhs.title == rhs.title
            && lhs.meta == rhs.meta && lhs.query == rhs.query && lhs.playTitle == rhs.playTitle && lhs.openTitle == rhs.openTitle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(posterPath)
        hasher.combine(title)
        hasher.combine(meta)
        hasher.combine(query)
        hasher.combine(playTitle)
        hasher.combine(openTitle)
    }

    func makeContentView() -> UIView & UIContentView {
        TVSearchTopResultContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TVSearchTopResultConfiguration {
        self
    }
}

/// The best match for the query: its poster, what it is, and the two things to do with it. The cell
/// itself never takes focus; the Play and details buttons do.
final class TVSearchTopResultContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static let posterSize = CGSize(width: 200, height: 300)

    private let artwork = TVArtworkView(kind: .poster, nominalSize: TVSearchTopResultContentView.posterSize, placeholderSymbol: "film")
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let buttonRow = UIStackView()
    private let playButton = TVButton.make(.primary, title: "Play", symbol: "play.fill", action: {})
    private let openButton = TVButton.make(.glass, title: "Details", action: {})
    private var onPlay: (@MainActor () -> Void)?
    private var onOpen: (@MainActor () -> Void)?

    init(configuration: TVSearchTopResultConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        buildHierarchy()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        playButton.isHidden ? [openButton] : [playButton]
    }

    private func buildHierarchy() {
        eyebrowLabel.text = "TOP RESULT"
        eyebrowLabel.font = TVCardTypography.eyebrow
        eyebrowLabel.textColor = Theme.Color.accentText
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        metaLabel.font = Theme.Font.callout
        metaLabel.textColor = Theme.Color.labelSecondary

        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        openButton.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .primaryActionTriggered)
        playButton.accessibilityIdentifier = "search.top.play"
        openButton.accessibilityIdentifier = "search.top.open"
        buttonRow.axis = .horizontal
        buttonRow.spacing = Theme.Space.m
        buttonRow.addArrangedSubview(playButton)
        buttonRow.addArrangedSubview(openButton)

        let text = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, metaLabel, buttonRow])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.m, after: metaLabel)
        text.translatesAutoresizingMaskIntoConstraints = false

        artwork.translatesAutoresizingMaskIntoConstraints = false
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

    private func apply() {
        guard let configuration = configuration as? TVSearchTopResultConfiguration else { return }
        onPlay = configuration.onPlay
        onOpen = configuration.onOpen
        titleLabel.attributedText = highlighted(configuration.title, query: configuration.query)
        metaLabel.text = configuration.meta
        artwork.setArtwork(path: configuration.posterPath, placeholderSymbol: configuration.placeholderSymbol)

        playButton.isHidden = configuration.playTitle == nil
        if let playTitle = configuration.playTitle {
            playButton.configuration = TVButton.configuration(.primary, title: playTitle, symbol: "play.fill")
            playButton.accessibilityLabel = "\(playTitle) \(configuration.title)"
        }
        openButton.configuration = TVButton.configuration(.glass, title: configuration.openTitle)
        openButton.accessibilityLabel = "\(configuration.openTitle), \(configuration.title)"
    }

    private func highlighted(_ text: String, query: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: Theme.Font.title2, .foregroundColor: Theme.Color.label]
        )
        guard let query, !query.isEmpty else { return result }
        for range in SearchHighlight.matchRanges(of: query, in: text) {
            result.addAttribute(.foregroundColor, value: Theme.Color.accentText, range: range)
        }
        return result
    }
}

final class TVSearchTopResultCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }
}
