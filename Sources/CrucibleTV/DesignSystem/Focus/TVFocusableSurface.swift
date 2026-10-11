import CrucibleDesign
import UIKit

/// Base class of every custom focusable panel (stats tiles, info cards, the profile summary).
/// Focus lifts it: it scales up, gains a soft shadow and brightens, driven through the focus
/// animation coordinator so it moves in step with the system's own focus animation.
///
/// Select runs the `.primaryActionTriggered` actions (add them with `addAction(_:for:)`); a long
/// press on Select shows `contextMenuProvider`'s menu. Subclasses add their views to `contentView`.
class TVFocusableSurface: UIControl {
    let contentView = UIView()
    var contextMenuProvider: (@MainActor () -> UIMenu?)?

    var cornerRadius: CGFloat = Theme.Radius.m {
        didSet { applyShape() }
    }

    private let sheen = TVGradientView()
    private var showsFocus = false

    init(cornerRadius: CGFloat = Theme.Radius.m) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 36
        layer.shadowOffset = CGSize(width: 0, height: 22)

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

        isContextMenuInteractionEnabled = true
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
            UIView.animate(withDuration: TVMetrics.Duration.focus, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : self.focusTransform
            }
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        showsFocus = focused
        coordinator.addCoordinatedAnimations({
            self.transform = self.focusTransform
            self.applyAppearance(focused: focused)
        })
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = contextMenuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    private var focusTransform: CGAffineTransform {
        showsFocus ? CGAffineTransform(scaleX: TVMetrics.surfaceFocusedScale, y: TVMetrics.surfaceFocusedScale) : .identity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
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
        layer.shadowOpacity = focused ? 0.4 : 0
        sheen.alpha = focused ? 1 : 0
    }
}
