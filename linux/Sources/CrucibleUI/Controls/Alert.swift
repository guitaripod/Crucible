import Foundation
import Kiln

/// An alert (`UIAlertController` on the Apple TV): the screen dims behind a glass panel holding a title, a message, an
/// optional text field and the buttons stacked full width. The keyboard stays inside it, Escape picks the cancel button
/// (or just closes when there is none), Return in the field picks the first button, and focus goes back where it was.
@MainActor
public final class AlertView: View {
    public struct Action {
        public enum Role: Sendable {
            case normal, cancel, destructive
        }

        public var title: String
        public var role: Role
        public var handler: (() -> Void)?

        public init(_ title: String, role: Role = .normal, handler: (() -> Void)? = nil) {
            self.title = title
            self.role = role
            self.handler = handler
        }
    }

    /// The text field, when the alert asks for a name or an address.
    public let field: TextFieldView?
    public var onDismiss: (() -> Void)?
    private let heading: String
    private let message: String?
    private let actions: [Action]
    private let buttons: [ButtonView]
    private var appear = Animated(0)
    private var tone = GlassTone()
    private weak var returnFocus: View?

    /// An alert titled `title` with `actions` as its buttons, in order; `fieldPlaceholder` adds a text field above them.
    /// `secureField` shows the field's text as dots (a PIN).
    public init(title: String, message: String? = nil, actions: [Action], fieldPlaceholder: String? = nil, fieldText: String = "",
                secureField: Bool = false) {
        heading = title
        self.message = message?.isEmpty == true ? nil : message
        self.actions = actions.isEmpty ? [Action(Strings.lookup("OK"))] : actions
        buttons = self.actions.map { action in
            let button = ButtonView(style: .glass, title: action.title)
            button.isDestructive = action.role == .destructive
            return button
        }
        field = fieldPlaceholder.map { TextFieldView(placeholder: $0, symbol: nil) }
        super.init()
        if let field {
            field.isSecure = secureField
            field.setText(fieldText, notify: false)
            field.onSubmit = { [weak self] _ in self?.choose(self?.actions.firstIndex { $0.role != .cancel } ?? 0) }
            addSubview(field)
        }
        for (index, button) in buttons.enumerated() {
            button.onPress = { [weak self] in self?.choose(index) }
            addSubview(button)
        }
    }

    public override var accessibilityRole: AccessibilityRole { .alertDialog }
    public override var accessibilityLabel: String? { heading }
    public override var accessibilityHint: String? { message }

    /// An alert with only OK, for a result or a failure.
    public static func notice(title: String, message: String? = nil, in window: Window) {
        AlertView(title: title, message: message, actions: [Action(Strings.lookup("OK"), role: .cancel)]).present(in: window)
    }

    /// Asks before acting: `confirm` (in red for something that cannot be undone, the default), then Cancel.
    public static func confirm(title: String, message: String? = nil, confirm: String, role: Action.Role = .destructive, in window: Window,
                               action: @escaping () -> Void) {
        AlertView(title: title, message: message, actions: [
            Action(confirm, role: role, handler: action),
            Action(Strings.lookup("Cancel"), role: .cancel),
        ]).present(in: window)
    }

    /// The field's text, trimmed of surrounding spaces.
    public var text: String { field?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// Shows the alert over everything in `window`, focus on the field or the first button.
    public func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .spring(response: 0.3, dampingFraction: 0.9))
        startAnimating()
        window.focus.setVisible(true)
        window.focus.focus(field ?? buttons.first, animated: false)
    }

    public func dismiss() {
        guard superview != nil else { return }
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        removeFromSuperview()
        onDismiss?()
    }

    private func choose(_ index: Int) {
        guard actions.indices.contains(index) else { return }
        dismiss()
        actions[index].handler?()
    }

    public override var preferredFocusView: View? { field ?? buttons.first }
    public override var isFocusScope: Bool { true }
    public override var isPointerInteractive: Bool { true }
    public override var cursor: Cursor { .default }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .escape || event.key == .back else { return false }
        if let cancel = actions.firstIndex(where: { $0.role == .cancel }) {
            choose(cancel)
        } else {
            dismiss()
        }
        return true
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }
    public override func scrolled(_ event: ScrollEvent) -> Bool { true }

    // MARK: Layout

    private var inset: Float { Theme.current.metrics.tv(44) }
    private var gap: Float { Theme.current.metrics.tv(16) }
    private var panelWidth: Float { min(Theme.current.metrics.messageColumn, frame.width - Theme.current.metrics.sideMargin * 2) }

    private func headingLayout(scale: Float) -> TextLayout {
        TextLayout(heading, font: Theme.current.type.headline, maxWidth: panelWidth - inset * 2, maxLines: 4, alignment: .center, scale: scale)
    }

    private func messageLayout(scale: Float) -> TextLayout? {
        message.map { TextLayout($0, font: Theme.current.type.callout, maxWidth: panelWidth - inset * 2, maxLines: 16, alignment: .center, scale: scale) }
    }

    private var panel: Rect {
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        var height = inset * 2 + headingLayout(scale: scale).size.height
        if let text = messageLayout(scale: scale) { height += gap + text.size.height }
        if field != nil { height += gap * 2 + metrics.primaryControlHeight }
        height += gap * 2 + Float(buttons.count) * metrics.primaryControlHeight + Float(max(buttons.count - 1, 0)) * gap
        return Rect(x: ((frame.width - panelWidth) / 2).rounded(), y: max(((frame.height - height) / 2).rounded(), metrics.tv(40)),
                    width: panelWidth, height: height)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        let area = panel
        var y = area.y + inset + headingLayout(scale: scale).size.height
        if let text = messageLayout(scale: scale) { y += gap + text.size.height }
        if let field {
            y += gap * 2
            field.frame = Rect(x: area.x + inset, y: y, width: area.width - inset * 2, height: metrics.primaryControlHeight)
            y += metrics.primaryControlHeight
        }
        y += gap * 2
        for button in buttons {
            button.frame = Rect(x: area.x + inset, y: y, width: area.width - inset * 2, height: metrics.primaryControlHeight)
            y += metrics.primaryControlHeight + gap
        }
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [appear.advance(dt), tone.advance(dt)].contains(true)
        for button in buttons { button.alpha = appear.value }
        field?.alpha = appear.value
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let area = panel
        context.fill(bounds, color: Color.black.withSRGBAlpha(0.55 * appear.value))
        if tone.update(context, rect: area) { startAnimating() }
        context.faded(appear.value) { faded in
            faded.transformed(scale: 0.94 + 0.06 * appear.value, about: area.center) { inner in
                GlassStyle.capsule(in: area, radius: metrics.radiusL, light: Point(x: area.midX, y: area.minY - area.height), floating: true,
                                   tone: tone.value, context: &inner)
                let title = headingLayout(scale: scale)
                var y = area.y + inset
                inner.text(title, at: Point(x: area.x + inset, y: y), color: GlassStyle.label(tone: tone.value))
                y += title.size.height
                if let text = messageLayout(scale: scale) {
                    inner.text(text, at: Point(x: area.x + inset, y: y + gap), color: GlassStyle.secondaryLabel(tone: tone.value))
                }
            }
        }
    }
}
