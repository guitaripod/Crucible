import CrucibleDesign
import UIKit

/// Base class of every custom focusable panel (stats tiles, info cards, the profile summary).
/// Focus lifts it: it scales up, gains a soft shadow and brightens, driven through the focus
/// animation coordinator so it moves in step with the system's own focus animation.
///
/// Select runs the `.primaryActionTriggered` actions (add them with `addAction(_:for:)`). A plain
/// `UIControl` on tvOS receives the Select press but never sends that event itself (verified in the
/// simulator: the press arrives, no action fires), so the surface sends it exactly once when Select is
/// released. A second `.primaryActionTriggered` within 100 ms is dropped, so a subclass that still
/// sends its own action after Select is not doubled. A long press on Select shows
/// `contextMenuProvider`'s menu. Subclasses add their views to `contentView`.
class TVFocusableSurface: UIControl {
    let contentView = UIView()
    final var contextMenuProvider: (@MainActor () -> UIMenu?)? {
        didSet { isContextMenuInteractionEnabled = contextMenuProvider != nil }
    }

    var cornerRadius: CGFloat = Theme.Radius.m {
        didSet { applyShape() }
    }

    private static let repeatWindow: TimeInterval = 0.1

    private let sheen = TVGradientView()
    private var lastPrimaryActionUptime: TimeInterval = -1
    private var showsFocus = false

    init(cornerRadius: CGFloat = Theme.Radius.m) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        TVFocusLift.prepare(self)

        contentView.clipsToBounds = true
        contentView.isUserInteractionEnabled = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.insetsLayoutMarginsFromSafeArea = false
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Space.l,
            leading: Theme.Space.l,
            bottom: Theme.Space.l,
            trailing: Theme.Space.l
        )
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        sheen.setColors(
            [UIColor.white.withAlphaComponent(0.16), UIColor.white.withAlphaComponent(0)],
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 0.7, y: 0.9)
        )
        sheen.alpha = 0
        sheen.frame = bounds
        sheen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(sheen)

        isContextMenuInteractionEnabled = false
        applyShape()
        applyAppearance(focused: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVFocusableSurface, _: UITraitCollection) in
            view.applyAppearance(focused: view.showsFocus)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { isEnabled }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            TVMotion.animate(TVMetrics.Duration.focus, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? self.pressedTransform : TVFocusLift.transform(focused: self.showsFocus)
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        if presses.contains(where: { $0.type == .select }) {
            sendActions(for: .primaryActionTriggered)
        }
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        if controlEvents.contains(.primaryActionTriggered) {
            let now = ProcessInfo.processInfo.systemUptime
            let repeated = now - lastPrimaryActionUptime < Self.repeatWindow
            lastPrimaryActionUptime = now
            if repeated {
                let remaining = controlEvents.subtracting(.primaryActionTriggered)
                if !remaining.isEmpty { super.sendActions(for: remaining) }
                return
            }
        }
        super.sendActions(for: controlEvents)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        showsFocus = focused
        TVFocusLift.animate(self, focused: focused, with: coordinator) {
            self.applyAppearance(focused: focused)
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = contextMenuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    private var pressedTransform: CGAffineTransform {
        CGAffineTransform(scaleX: TVMetrics.Focus.pressedScale, y: TVMetrics.Focus.pressedScale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        TVFocusLift.updateShadowPath(of: self, cornerRadius: cornerRadius)
    }

    private func applyShape() {
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        contentView.layer.cornerRadius = cornerRadius
        contentView.layer.cornerCurve = .continuous
    }

    private func applyAppearance(focused: Bool) {
        contentView.backgroundColor = focused ? Theme.Color.surfaceHigh : Theme.Color.surface
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        sheen.alpha = focused ? 1 : 0
    }
}
