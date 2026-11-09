import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// The Plex / Everything switch under the range switcher, shown while Trakt is connected: Plex's own history, or
/// everything the viewer watched as Trakt knows it, under Trakt's mark. Everything carries a lock without Crucible Pro.
/// Like the range switcher it reports taps and leaves the selection to its owner, which may open the paywall instead.
final class StatsSourceChipsView: UIView {
    var onSource: ((StatsSource) -> Void)?

    private let metrics: StatsMetrics
    private let track = UIStackView()
    private var buttons: [StatsSource: UIButton] = [:]
    private var selected: StatsSource = .plex
    private var locked = false

    init(metrics: StatsMetrics = .platform) {
        self.metrics = metrics
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        track.axis = .horizontal
        track.distribution = .fillEqually
        track.spacing = 2
        track.isLayoutMarginsRelativeArrangement = true
        track.layoutMargins = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.rangeControl.minHeight),
        ])
        for source in StatsSource.allCases {
            let button = UIButton(configuration: .plain())
            button.isPointerInteractionEnabled = true
            button.accessibilityIdentifier = "stats.source.\(source.rawValue)"
            button.addAction(UIAction { [weak self] _ in
                Haptics.selection()
                self?.onSource?(source)
            }, for: .primaryActionTriggered)
            buttons[source] = button
            track.addArrangedSubview(button)
        }
        accessibilityLabel = String(localized: "History source", comment: "VoiceOver label of the Plex or Everything switch in Statistics")
        accessibilityContainerType = .semanticGroup
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ source: StatsSource) {
        selected = source
        refresh()
    }

    func setEverythingLocked(_ isLocked: Bool) {
        locked = isLocked
        refresh()
    }

    private func refresh() {
        let font = metrics.rangeControl.font.uiFont
        for (source, button) in buttons {
            let isSelected = source == selected
            var config = UIButton.Configuration.plain()
            config.title = source.title
            config.baseForegroundColor = isSelected ? Theme.Color.label : Theme.Color.labelSecondary
            config.background.backgroundColor = isSelected ? Theme.Color.surfaceHigh : .clear
            config.background.cornerRadius = 8
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
            config.titleLineBreakMode = .byTruncatingTail
            if source == .everything {
                config.image = locked ? ProLock.image(pointSize: 11) : Self.traktMark(height: font.capHeight * 1.5)
                config.imagePlacement = locked ? .trailing : .leading
                config.imagePadding = 6
            }
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = font
                return outgoing
            }
            button.configuration = config
            button.accessibilityLabel = source.accessibilityLabel
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            button.accessibilityHint = source == .everything && locked ? String(localized: "Requires Crucible Pro") : nil
        }
    }

    private static func traktMark(height: CGFloat) -> UIImage? {
        guard let mark = BrandMark.trakt.image, mark.size.height > 0 else { return nil }
        let size = CGSize(width: (height * mark.size.width / mark.size.height).rounded(), height: height.rounded())
        return UIGraphicsImageRenderer(size: size).image { _ in mark.draw(in: CGRect(origin: .zero, size: size)) }.withRenderingMode(.alwaysOriginal)
    }
}
