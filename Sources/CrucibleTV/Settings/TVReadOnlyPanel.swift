import CrucibleDesign
import UIKit

/// A block of read-only information (the account, the server card, log counts). VoiceOver on tvOS
/// follows the focus engine, so information nothing can focus is unreachable for it; while
/// VoiceOver runs the panel becomes a focus stop that VoiceOver reads as one element, with a thin
/// ember rim as its focus style. Sighted users never meet a dead focus stop.
class TVReadOnlyPanel: UIView {
    private static let rimOutset: CGFloat = 14

    let contentView = UIView()
    var spokenLabel: (() -> String?)?
    var spokenValue: (() -> String?)?

    private let rim = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        rim.layer.cornerRadius = Theme.Radius.m
        rim.layer.cornerCurve = .continuous
        rim.layer.borderWidth = 3
        rim.layer.borderColor = Theme.Color.accent.cgColor
        rim.alpha = 0
        rim.isUserInteractionEnabled = false
        rim.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rim.topAnchor.constraint(equalTo: topAnchor, constant: -Self.rimOutset),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Self.rimOutset),
            rim.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Self.rimOutset),
            rim.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.rimOutset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A panel around an existing view, reading `label` aloud.
    convenience init(wrapping content: UIView, label: @escaping () -> String?, value: (() -> String?)? = nil) {
        self.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spokenLabel = label
        spokenValue = value
    }

    override var accessibilityLabel: String? {
        get { spokenLabel?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityValue: String? {
        get { spokenValue?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    override var canBecomeFocused: Bool { Self.isReachable }

    /// True while VoiceOver is running; DEBUG builds can force it with `CRUCIBLE_VOICEOVER=1` so UI
    /// tests can walk the focus path VoiceOver would take.
    static var isReachable: Bool {
        if UIAccessibility.isVoiceOverRunning { return true }
        #if DEBUG
        return ProcessInfo.processInfo.environment["CRUCIBLE_VOICEOVER"] == "1"
        #else
        return false
        #endif
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ self.rim.alpha = focused ? 1 : 0 })
    }
}
