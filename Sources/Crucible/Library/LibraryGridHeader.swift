@preconcurrency import UIKit

struct ContinueBannerModel: Equatable {
    let itemId: String
    let detail: String
    let artPath: String?
    let spokenLabel: String
}

/// The block that scrolls above the poster grid: filter chips and, when something in the library
/// is part-watched, the compact Continue banner.
struct LibraryHeaderConfiguration: UIContentConfiguration {
    var chips: [FilterChipsView.Chip] = []
    var banner: ContinueBannerModel?
    var onChipSelect: ((String) -> Void)?
    var onBannerPlay: (() -> Void)?
    var onBannerDetails: (() -> Void)?

    func makeContentView() -> UIView & UIContentView {
        LibraryHeaderContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> LibraryHeaderConfiguration {
        self
    }
}

final class LibraryHeaderContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let chipsView = FilterChipsView()
    private let banner = ContinueBannerView()
    private let bannerContainer = UIView()

    init(configuration: LibraryHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: bannerContainer.topAnchor),
            banner.bottomAnchor.constraint(equalTo: bannerContainer.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor, constant: Theme.Space.m),
            banner.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor, constant: -Theme.Space.m),
        ])

        let stack = UIStackView(arrangedSubviews: [chipsView, bannerContainer])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xxs)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.xxs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
        ])
    }

    private func apply() {
        guard let config = configuration as? LibraryHeaderConfiguration else { return }
        chipsView.setChips(config.chips)
        chipsView.onSelect = config.onChipSelect
        bannerContainer.isHidden = config.banner == nil
        banner.onPlay = config.onBannerPlay
        banner.onDetails = config.onBannerDetails
        if let model = config.banner {
            banner.apply(model)
        }
    }
}

/// A 56pt surface row that resumes the library's most recent in-progress title in one tap.
final class ContinueBannerView: UIControl {
    var onPlay: (() -> Void)?
    var onDetails: (() -> Void)?

    private let thumbView = UIImageView()
    private let captionLabel = UILabel()
    private let detailLabel = UILabel()
    private let playCircle = UIView()
    private var imageTask: Task<Void, Never>?
    private var model: ContinueBannerModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        addAction(UIAction { [weak self] _ in
            self?.onPlay?()
        }, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ContinueBannerView, _: UITraitCollection) in
            view.layer.borderColor = Theme.Color.separator.resolvedColor(with: view.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    override var isHighlighted: Bool {
        didSet { animatePress() }
    }

    private func setupViews() {
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 8
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = Theme.Color.surfaceRaised

        captionLabel.text = "CONTINUE"
        captionLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 16)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = Theme.Color.accentText

        detailLabel.font = Theme.Font.scaled(.subheadline, 14, .semibold)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.label
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.numberOfLines = 2

        playCircle.backgroundColor = Theme.Color.accent
        playCircle.layer.cornerRadius = 17
        let glyph = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
        glyph.tintColor = Theme.Color.onAccent
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        playCircle.addSubview(glyph)

        let textStack = UIStackView(arrangedSubviews: [captionLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let row = UIStackView(arrangedSubviews: [thumbView, textStack, playCircle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Theme.Space.xs),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Theme.Space.xs),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.xs),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),

            thumbView.widthAnchor.constraint(equalToConstant: 64),
            thumbView.heightAnchor.constraint(equalToConstant: 40),
            playCircle.widthAnchor.constraint(equalToConstant: 34),
            playCircle.heightAnchor.constraint(equalToConstant: 34),
            glyph.centerXAnchor.constraint(equalTo: playCircle.centerXAnchor, constant: 1),
            glyph.centerYAnchor.constraint(equalTo: playCircle.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Plays from where you left off."
        isContextMenuInteractionEnabled = true
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Resume", image: UIImage(systemName: "play.fill")) { _ in
                    self?.onPlay?()
                },
                UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in
                    self?.onDetails?()
                },
            ])
        })
    }

    func apply(_ model: ContinueBannerModel) {
        detailLabel.text = model.detail
        accessibilityLabel = model.spokenLabel
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "View Details") { [weak self] _ in
                self?.onDetails?()
                return true
            },
        ]
        guard model.artPath != self.model?.artPath else {
            self.model = model
            return
        }
        self.model = model
        imageTask?.cancel()
        thumbView.image = nil
        guard let path = model.artPath else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: 192)
            guard !Task.isCancelled, let self, let image else { return }
            self.thumbView.image = image
        }
    }

    private func animatePress() {
        let pressed = isHighlighted
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = pressed ? 0.7 : 1
            return
        }
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = pressed ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        }
    }
}
