import CrucibleCore
import CrucibleDesign
import UIKit

enum HistoryMetrics {
    static let posterSize = CGSize(width: 80, height: 120)
    static let rowHeight: CGFloat = 144
    static let posterRadius: CGFloat = Theme.Radius.xs
    static let rowInset: CGFloat = 12
    static let buttonSpacing: CGFloat = Theme.Space.l
    static let dayHeaderHeight: CGFloat = 64
    static let daySectionBottomInset: CGFloat = 40
    static let noMatchesHeight: CGFloat = 460
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

    private func buildHierarchy() {
        plate.isUserInteractionEnabled = false
        plate.translatesAutoresizingMaskIntoConstraints = false
        contentView.insertSubview(plate, at: 0)

        artwork.adjustsImageWhenAncestorFocused = false
        artwork.layer.cornerRadius = HistoryMetrics.posterRadius
        artwork.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = TVFont.rowTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = TVFont.cardSubtitle
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

/// One watch-history row: the focusable plate and, beside it, the glass play-again button. Hosted in
/// a `TVHostCell`, so the cell never takes focus: the plate (Select opens detail) and the button
/// (Select plays) are the two focus targets.
final class HistoryRowView: UIStackView {
    private let surface = HistoryRowSurface()
    private let playButton = TVButton.make(.glass, title: nil, symbol: "play.fill")
    private var onSelect: (@MainActor () -> Void)?
    private var onPlay: (@MainActor () -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = HistoryMetrics.buttonSpacing
        surface.addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        playButton.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(surface)
        addArrangedSubview(playButton)
        surface.heightAnchor.constraint(equalToConstant: HistoryMetrics.rowHeight).isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

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
}
