import UIKit

/// A 36pt glass button whose touch area extends to the 44pt minimum.
final class ExpandedHitButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: min(0, (bounds.width - Theme.Size.minTarget) / 2), dy: min(0, (bounds.height - Theme.Size.minTarget) / 2)).contains(point)
    }
}

struct HistoryRowConfiguration: UIContentConfiguration {
    var posterPath: String?
    var title: String
    var subtitle: String
    var meta: String?
    var isPlayEnabled: Bool
    var onPlay: () -> Void

    func makeContentView() -> UIView & UIContentView { HistoryRowContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> HistoryRowConfiguration { self }
}

final class HistoryRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private static let posterWidth: CGFloat = 44

    private let posterView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let metaLabel = UILabel()
    private let playButton = ExpandedHitButton()
    private var onPlay: () -> Void = {}
    private var imageTask: Task<Void, Never>?
    private var loadedPath: String?

    init(configuration: HistoryRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.layer.cornerRadius = 7
        posterView.layer.cornerCurve = .continuous
        posterView.layer.borderWidth = 1
        posterView.layer.borderColor = Theme.Color.artHairline.cgColor
        posterView.isAccessibilityElement = false
        posterView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            posterView.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: Self.posterWidth * Theme.Size.posterAspect),
        ])

        titleLabel.font = Theme.Font.scaled(.callout, 16, .semibold)
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Font.footnote
        subtitleLabel.textColor = Theme.Color.labelSecondary
        metaLabel.font = Theme.Font.caption1Regular
        metaLabel.textColor = Theme.Color.labelTertiary
        for label in [titleLabel, subtitleLabel, metaLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
        }

        let texts = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, metaLabel])
        texts.axis = .vertical
        texts.spacing = 1

        var config = ThemeButton.glassConfiguration(symbol: "play.fill")
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.contentInsets = .zero
        playButton.configuration = config
        playButton.accessibilityLabel = "Play again"
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay() }, for: .primaryActionTriggered)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        let root = UIStackView(arrangedSubviews: [posterView, texts, playButton])
        root.spacing = 14
        root.alignment = .center
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

        accessibilityElements = [titleLabel, subtitleLabel, metaLabel, playButton]
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func apply() {
        guard let config = configuration as? HistoryRowConfiguration else { return }
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = config.subtitle.isEmpty
        metaLabel.text = config.meta
        metaLabel.isHidden = config.meta == nil
        onPlay = config.onPlay
        playButton.isEnabled = config.isPlayEnabled
        playButton.alpha = config.isPlayEnabled ? 1 : 0.5
        loadPoster(path: config.posterPath)
    }

    private func loadPoster(path: String?) {
        guard path != loadedPath else { return }
        loadedPath = path
        imageTask?.cancel()
        posterView.image = nil
        guard let path else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: Int(Self.posterWidth * 3))
            guard !Task.isCancelled, let self, loadedPath == path else { return }
            posterView.image = image
        }
    }
}

struct HistoryControlsConfiguration: UIContentConfiguration {
    var chips: [FilterChipsView.Chip]
    var summary: String?
    var onSelect: (String) -> Void

    func makeContentView() -> UIView & UIContentView { HistoryControlsContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> HistoryControlsConfiguration { self }
}

final class HistoryControlsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private let chipsView = FilterChipsView()
    private let summaryLabel = UILabel()

    init(configuration: HistoryControlsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()

        summaryLabel.font = Theme.Font.footnote
        summaryLabel.textColor = Theme.Color.labelSecondary
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 0

        let summaryHolder = UIView()
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryHolder.addSubview(summaryLabel)
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: summaryHolder.topAnchor),
            summaryLabel.bottomAnchor.constraint(equalTo: summaryHolder.bottomAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: summaryHolder.leadingAnchor, constant: Theme.Space.m),
            summaryLabel.trailingAnchor.constraint(equalTo: summaryHolder.trailingAnchor, constant: -Theme.Space.m),
        ])

        let root = UIStackView(arrangedSubviews: [chipsView, summaryHolder])
        root.axis = .vertical
        root.spacing = Theme.Space.s
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: Theme.Space.s, leading: 0, bottom: Theme.Space.xs, trailing: 0))
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? HistoryControlsConfiguration else { return }
        chipsView.onSelect = config.onSelect
        chipsView.setChips(config.chips)
        summaryLabel.text = config.summary
        summaryLabel.superview?.isHidden = config.summary == nil
    }
}
