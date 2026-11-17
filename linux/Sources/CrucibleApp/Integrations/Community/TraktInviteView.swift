import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The invitation a title page shows where Trakt's community would be while Trakt is not connected (`TraktInvite`): Trakt's
/// mark beside what connecting adds to this title, then Connect Trakt (or Connect Again) and a quieter Not Now, on a panel
/// within the page's margins, so it never outshouts the page's Play. Not Now fades it away before the page closes the gap.
@MainActor
final class TraktInviteView: View {
    var onConnect: (() -> Void)?
    var onDismissed: (() -> Void)?

    private var invite: TraktInvite?
    private let mark = BrandMarkView("trakt")
    private let connect = ButtonView(style: .glass, title: TraktCopy.connect, symbol: "link")
    private let notNow = ButtonView(style: .plain, title: TraktInvite.notNow)
    private var appear = Animated(1)
    private var isDismissing = false

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [mark, connect, notNow].forEach(addSubview)
        connect.onPress = { [weak self] in self?.onConnect?() }
        notNow.onPress = { [weak self] in self?.dismiss() }
    }

    /// Shows `invite`'s words, at full strength again when it was fading.
    func apply(_ newInvite: TraktInvite) {
        if newInvite != invite {
            invite = newInvite
            connect.title = newInvite.action
            superview?.setNeedsLayout()
            setNeedsLayout()
            setNeedsDisplay()
        }
        if !isDismissing, appear.value < 1 { appear.reset(1) }
        alpha = appear.value
    }

    override var preferredFocusView: View? { connect }

    /// Either button taking the focus brings the whole panel into view, not only the button.
    override func reveal(_ rect: Rect, of view: View, animated: Bool) {
        super.reveal(bounds, of: view, animated: animated)
    }
    override var accessibilityRole: AccessibilityRole { .group }
    override var accessibilityLabel: String? { invite.map { "\($0.title). \($0.message)" } }

    /// Remembers Not Now for this computer and fades the panel out, then tells the page it is gone.
    private func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        WelcomeLedger.shared.dismissTraktInvite()
        appear.set(0, animation: .fade)
        if !appear.isAnimating { finishDismissal() }
        startAnimating()
    }

    private func finishDismissal() {
        isDismissing = false
        onDismissed?()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = appear.advance(dt)
        alpha = appear.value
        if !moving, isDismissing { finishDismissal() }
        return moving
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var inset: Float { metrics.tv(40) }
    private var markSide: Float { metrics.tv(88) }
    private var gap: Float { metrics.tv(32) }

    private func textWidth(_ width: Float) -> Float {
        min(width - inset * 2 - markSide - gap, metrics.messageColumn)
    }

    private func layouts(width: Float) -> (title: TextLayout, message: TextLayout)? {
        guard let invite else { return nil }
        let scale = window?.scale ?? 1
        let column = textWidth(width)
        return (TextLayout(invite.title, font: Theme.current.type.headline, maxWidth: column, maxLines: 2, scale: scale),
                TextLayout(invite.message, font: Theme.current.type.body, maxWidth: column, maxLines: 4, scale: scale))
    }

    private var buttonsHeight: Float { metrics.primaryControlHeight }

    override func sizeThatFits(_ size: Size) -> Size {
        guard let text = layouts(width: size.width) else { return Size(width: size.width, height: 0) }
        let textHeight = text.title.size.height + metrics.tv(12) + text.message.size.height
        return Size(width: size.width, height: inset * 2 + max(markSide, textHeight) + metrics.tv(32) + buttonsHeight)
    }

    override func layoutSubviews() {
        mark.frame = Rect(x: inset, y: inset, width: markSide, height: markSide)
        guard let text = layouts(width: frame.width) else { return }
        let x = inset + markSide + gap
        let textHeight = text.title.size.height + metrics.tv(12) + text.message.size.height
        let y = inset + max(markSide, textHeight) + metrics.tv(32)
        let connectWidth = connect.sizeThatFits(Size(width: frame.width, height: 0)).width
        let notNowWidth = notNow.sizeThatFits(Size(width: frame.width, height: 0)).width
        connect.frame = Rect(x: x, y: y, width: max(connectWidth, metrics.tv(320)), height: buttonsHeight)
        notNow.frame = Rect(x: connect.frame.maxX + metrics.tv(20), y: y + ((buttonsHeight - metrics.plainControlHeight) / 2).rounded(),
                            width: notNowWidth, height: metrics.plainControlHeight)
    }

    override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        context.fill(bounds, radius: metrics.radiusM, color: palette.surface)
        context.stroke(bounds, radius: metrics.radiusM, width: 1, color: palette.separator)
        guard let text = layouts(width: frame.width) else { return }
        let x = inset + markSide + gap
        context.text(text.title, at: Point(x: x, y: inset), color: palette.label)
        context.text(text.message, at: Point(x: x, y: inset + text.title.size.height + metrics.tv(12)), color: palette.labelSecondary)
    }
}
