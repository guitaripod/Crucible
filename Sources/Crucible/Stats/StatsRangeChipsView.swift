import CrucibleDesign
import CrucibleStats
import CrucibleStatsUI
import UIKit

/// The Week / Month / Year / All switcher, drawn like the system segmented control it replaces so the ranges that need Crucible
/// Pro can carry a lock and say so to VoiceOver. It reports taps and leaves the selection to its owner, which may send the
/// user to the paywall instead of changing range.
final class StatsRangeChipsView: UIView {
    var onRange: ((StatsRange) -> Void)?

    private let metrics: StatsMetrics
    private let track = UIStackView()
    private var buttons: [StatsRange: UIButton] = [:]
    private var selected: StatsRange = .week
    private var locked: Set<StatsRange> = []

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

        for range in StatsRange.allCases {
            let button = UIButton(configuration: .plain())
            button.addAction(UIAction { [weak self] _ in
                Haptics.selection()
                self?.onRange?(range)
            }, for: .primaryActionTriggered)
            buttons[range] = button
            track.addArrangedSubview(button)
        }
        isAccessibilityElement = false
        accessibilityLabel = "Time range"
        accessibilityContainerType = .semanticGroup
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ range: StatsRange) {
        selected = range
        refresh()
    }

    func setLocked(_ ranges: Set<StatsRange>) {
        locked = ranges
        refresh()
    }

    private func refresh() {
        for (range, button) in buttons {
            let isSelected = range == selected
            let isLocked = locked.contains(range)
            var config = UIButton.Configuration.plain()
            config.title = range.title
            config.baseForegroundColor = isSelected ? Theme.Color.label : Theme.Color.labelSecondary
            config.background.backgroundColor = isSelected ? Theme.Color.surfaceHigh : .clear
            config.background.cornerRadius = 8
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            config.titleLineBreakMode = .byTruncatingTail
            if isLocked {
                config.image = ProLock.image(pointSize: 11)
                config.imagePlacement = .trailing
                config.imagePadding = 4
            }
            let font = metrics.rangeControl.font.uiFont
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = font
                return outgoing
            }
            button.configuration = config
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            button.accessibilityHint = isLocked ? "Requires Crucible Pro" : nil
        }
    }
}
