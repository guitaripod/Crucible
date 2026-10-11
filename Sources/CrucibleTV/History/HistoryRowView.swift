import CrucibleCore
import CrucibleDesign
import UIKit

enum HistoryMetrics {
    static let posterSize = CGSize(width: 80, height: 120)
    static let rowHeight: CGFloat = 144
    static let posterRadius: CGFloat = Theme.Radius.xs
    static let rowInset: CGFloat = 12
    static let buttonSpacing: CGFloat = Theme.Space.l
    static let titleTopInset: CGFloat = 130
    static let dayHeaderHeight: CGFloat = 64
    static let daySectionBottomInset: CGFloat = 40
}

/// The focusable part of a history row: a light plate with the poster, the title and subtitle and
/// the time of day. Focus lifts it like a `TVRowCell` and turns the plate light with dark text.
final class HistoryRowSurface: TVFocusableSurface {
    private let plate = UIView()
    private let artwork = TVArtworkView(kind: .poster, nominalSize: HistoryMetrics.posterSize, placeholderSymbol: "film")
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let timeLabel = UILabel()

    init() {
        super.init(cornerRadius: Theme.Radius.m)
        buildHierarchy()
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with row: HistoryRowPresentation) {
        artwork.setArtwork(path: row.posterPath, placeholderSymbol: "film")
        titleLabel.text = row.title
        subtitleLabel.text = row.subtitle
        timeLabel.text = row.timeText
        timeLabel.isHidden = (row.timeText ?? "").isEmpty
        accessibilityLabel = [row.title, row.subtitle, row.timeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityHint = "Opens details"
    }

    func resetArtwork() {
        artwork.reset()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ self.applyFocus(focused) })
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.contains(where: { $0.type == .select }) {
            sendActions(for: .primaryActionTriggered)
        }
    }

    private func buildHierarchy() {
        plate.isUserInteractionEnabled = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        contentView.insertSubview(plate, at: 0)

        artwork.adjustsImageWhenAncestorFocused = false
        artwork.layer.cornerRadius = HistoryMetrics.posterRadius
        artwork.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Font.scaled(.callout, 31, .semibold, maximum: 42)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = TVCardTypography.subtitle
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = TVMetrics.Card.captionLabelSpacing

        timeLabel.font = Theme.Font.body
        timeLabel.textAlignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [artwork, text, timeLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        row.insetsLayoutMarginsFromSafeArea = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(
            top: HistoryMetrics.rowInset,
            left: HistoryMetrics.rowInset,
            bottom: HistoryMetrics.rowInset,
            right: TVMetrics.Row.horizontalInset
        )
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            artwork.widthAnchor.constraint(equalToConstant: HistoryMetrics.posterSize.width),
            artwork.heightAnchor.constraint(equalToConstant: HistoryMetrics.posterSize.height),
        ])
    }

    private func applyFocus(_ focused: Bool) {
        plate.backgroundColor = focused ? TVColor.focusFill : Theme.Color.surfaceRaised
        titleLabel.textColor = focused ? TVColor.onFocusFill : Theme.Color.label
        subtitleLabel.textColor = focused ? TVColor.onFocusFillSecondary : Theme.Color.labelSecondary
        timeLabel.textColor = focused ? TVColor.onFocusFillSecondary : Theme.Color.labelSecondary
    }
}

/// One watch-history row: the focusable plate and, beside it, the glass play-again button. The cell
/// is not focusable itself; the plate (Select opens detail) and the button (Select plays) are.
final class HistoryRowCell: UICollectionViewCell {
    private let surface = HistoryRowSurface()
    private let playButton: UIButton
    private var onSelect: (@MainActor () -> Void)?
    private var onPlay: (@MainActor () -> Void)?

    override init(frame: CGRect) {
        playButton = TVButton.make(.glass, title: nil, symbol: "play.fill") {}
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false

        surface.addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        playButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [surface, playButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = HistoryMetrics.buttonSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.heightAnchor.constraint(equalToConstant: HistoryMetrics.rowHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [surface] }

    static func registration(
        isBusy: @escaping @MainActor (HistoryItem) -> Bool,
        onSelect: @escaping @MainActor (HistoryItem) -> Void,
        onPlay: @escaping @MainActor (HistoryItem) -> Void
    ) -> UICollectionView.CellRegistration<HistoryRowCell, HistoryItem> {
        UICollectionView.CellRegistration<HistoryRowCell, HistoryItem> { cell, _, item in
            cell.configure(with: item, isBusy: isBusy(item), onSelect: { onSelect(item) }, onPlay: { onPlay(item) })
        }
    }

    func configure(
        with item: HistoryItem,
        isBusy: Bool,
        onSelect: @escaping @MainActor () -> Void,
        onPlay: @escaping @MainActor () -> Void
    ) {
        let row = item.row
        self.onSelect = onSelect
        self.onPlay = onPlay
        surface.configure(with: row)
        surface.accessibilityIdentifier = "history.row.\(item.uniqueId)"

        var configuration = playButton.configuration
        configuration?.showsActivityIndicator = isBusy
        configuration?.image = isBusy ? nil : UIImage(systemName: "play.fill")
        playButton.configuration = configuration
        playButton.accessibilityLabel = "Play \(row.title) again"
        playButton.accessibilityIdentifier = "history.play.\(item.uniqueId)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        surface.resetArtwork()
        onSelect = nil
        onPlay = nil
    }
}
