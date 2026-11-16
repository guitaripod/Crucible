import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The demo's two full-window messages, the welcome and the finale (`TVDemoModalViewController`): the onboarding backdrop
/// and two columns centred in the window, the text on the left and what the viewer can do on the right. With a list of
/// steps (the welcome) the steps take the right column and the buttons sit under the text. The keyboard stays inside it,
/// and Escape picks the quietest button.
@MainActor
final class DemoSheetView: View {
    struct Action {
        let title: String
        let isPrimary: Bool
        let handler: () -> Void
    }

    private let heading: String
    private let message: String
    private let steps: [DemoTourStep]
    private let actions: [Action]
    private let buttons: [ButtonView]
    private let quietest: Int
    private var appear = Animated(0)
    private weak var returnFocus: View?
    private var isDismissing = false

    /// `quietest` is the index of the action Escape picks.
    init(title: String, message: String, steps: [DemoTourStep] = [], actions: [Action], quietest: Int) {
        heading = title
        self.message = message
        self.steps = steps
        self.actions = actions
        self.quietest = quietest
        buttons = actions.map { ButtonView(style: $0.isPrimary ? .primary : .glass, title: $0.title) }
        super.init()
        for (index, button) in buttons.enumerated() {
            button.onPress = { [weak self] in self?.choose(index) }
            addSubview(button)
        }
    }

    /// Shows the sheet over everything in `window`, focus on its first button.
    func present(in window: Window) {
        returnFocus = window.focusedView
        window.contentView.addSubview(self)
        frame = window.contentView.bounds
        appear.set(1, animation: .fade)
        startAnimating()
        window.focus.setVisible(true)
        window.focus.focus(buttons.first, animated: false)
    }

    /// Fades the sheet out and gives the focus back to where it was, then runs `completion`.
    func dismiss(completion: (() -> Void)? = nil) {
        guard superview != nil, !isDismissing else { return }
        isDismissing = true
        if let focus = returnFocus, focus.window != nil { window?.focus.focus(focus, animated: false) }
        appear.set(0, animation: .fade)
        if !appear.isAnimating { removeFromSuperview() }
        startAnimating()
        completion?()
    }

    private func choose(_ index: Int) {
        guard actions.indices.contains(index), !isDismissing else { return }
        dismiss(completion: actions[index].handler)
    }

    override var preferredFocusView: View? { buttons.first }
    override var isFocusScope: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.key == .escape || event.key == .back || event.key == .menu else { return false }
        choose(quietest)
        return true
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }
    override func scrolled(_ event: ScrollEvent) -> Bool { true }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = appear.advance(dt)
        alpha = appear.value
        if !moving, isDismissing { removeFromSuperview() }
        return moving
    }

    // MARK: Layout

    private var metrics: Metrics { Theme.current.metrics }
    private var columnGap: Float { metrics.tv(96) }
    private var textGap: Float { metrics.tv(24) }
    private var buttonGap: Float { metrics.tv(20) }
    private var buttonWidth: Float { metrics.tv(560) }

    /// Whether the window is wide enough for the two columns side by side; a narrow one stacks them.
    private var isSideBySide: Bool { frame.width - metrics.sideMargin * 2 >= metrics.tv(1200) }

    private var columnWidth: Float {
        let room = frame.width - metrics.sideMargin * 2
        return isSideBySide ? min(metrics.tv(780), (room - columnGap) / 2) : min(metrics.tv(900), room)
    }

    private func titleLayout(scale: Float) -> TextLayout {
        TextLayout(heading, font: Theme.current.type.largeTitle, maxWidth: columnWidth, maxLines: 3, scale: scale)
    }

    private func messageLayout(scale: Float) -> TextLayout {
        TextLayout(message, font: Theme.current.type.body, maxWidth: columnWidth, maxLines: 8, scale: scale)
    }

    private func stepsHeadingLayout(scale: Float) -> TextLayout {
        TextLayout(String(localized: "Things to try").uppercased(), font: Theme.current.type.eyebrow, maxWidth: columnWidth, maxLines: 1, scale: scale)
    }

    private func stepLayouts(_ step: DemoTourStep, scale: Float) -> (title: TextLayout, detail: TextLayout) {
        let width = columnWidth - metrics.rowIconWell - metrics.tv(24)
        return (TextLayout(step.title, font: Theme.current.type.cardTitle, maxWidth: width, maxLines: 2, scale: scale),
                TextLayout(Self.keepingRangesWhole(step.detail), font: Theme.current.type.cardSubtitle, maxWidth: width, maxLines: 4, scale: scale))
    }

    /// The text with word joiners around its en dashes, so a range such as A–Z never breaks across lines.
    private static func keepingRangesWhole(_ text: String) -> String {
        text.replacingOccurrences(of: "–", with: "\u{2060}–\u{2060}")
    }

    private var buttonsHeight: Float {
        Float(buttons.count) * metrics.primaryControlHeight + Float(max(buttons.count - 1, 0)) * buttonGap
    }

    private func textHeight(scale: Float) -> Float {
        var height = titleLayout(scale: scale).size.height + textGap + messageLayout(scale: scale).size.height
        if !steps.isEmpty { height += metrics.tv(48) + buttonsHeight }
        return height
    }

    private func trailingHeight(scale: Float) -> Float {
        guard !steps.isEmpty else { return buttonsHeight }
        var height = stepsHeadingLayout(scale: scale).size.height
        for step in steps {
            let text = stepLayouts(step, scale: scale)
            height += metrics.tv(28) + max(metrics.rowIconWell, text.title.size.height + metrics.tv(6) + text.detail.size.height)
        }
        return height
    }

    /// Where the two columns go: their origins, centred together in the window.
    private func columns(scale: Float) -> (leading: Point, trailing: Point) {
        let leadingHeight = textHeight(scale: scale)
        let trailing = trailingHeight(scale: scale)
        if isSideBySide {
            let total = columnWidth * 2 + columnGap
            let x = ((frame.width - total) / 2).rounded()
            return (Point(x: x, y: ((frame.height - leadingHeight) / 2).rounded()),
                    Point(x: x + columnWidth + columnGap, y: ((frame.height - trailing) / 2).rounded()))
        }
        let total = leadingHeight + metrics.tv(56) + trailing
        let x = ((frame.width - columnWidth) / 2).rounded()
        let y = max(((frame.height - total) / 2).rounded(), metrics.tv(48))
        return (Point(x: x, y: y), Point(x: x, y: y + leadingHeight + metrics.tv(56)))
    }

    override func layoutSubviews() {
        let scale = window?.scale ?? 1
        let origins = columns(scale: scale)
        var y: Float
        if steps.isEmpty {
            y = origins.trailing.y
        } else {
            y = origins.leading.y + titleLayout(scale: scale).size.height + textGap + messageLayout(scale: scale).size.height + metrics.tv(48)
        }
        let x = steps.isEmpty ? origins.trailing.x : origins.leading.x
        let width = steps.isEmpty ? columnWidth : min(buttonWidth, columnWidth)
        for button in buttons {
            button.frame = Rect(x: x, y: y, width: width, height: metrics.primaryControlHeight)
            y += metrics.primaryControlHeight + buttonGap
        }
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        context.fill(bounds, color: theme.palette.canvas)
        context.glow(in: bounds, radius: 0, center: Point(x: bounds.midX, y: bounds.height * 0.4), glowRadius: bounds.width * 0.55,
                     color: Color(srgbRed: 0.18, green: 0.10, blue: 0.04).withAlpha(0.95))
        let origins = columns(scale: scale)
        let title = titleLayout(scale: scale)
        context.text(title, at: origins.leading, color: theme.palette.label)
        context.text(messageLayout(scale: scale), at: Point(x: origins.leading.x, y: origins.leading.y + title.size.height + textGap),
                     color: theme.palette.labelSecondary)
        guard !steps.isEmpty else { return }
        drawSteps(at: origins.trailing, scale: scale, context: &context)
    }

    /// "Things to try": each step's symbol in a tinted well beside its name and one line.
    private func drawSteps(at origin: Point, scale: Float, context: inout DrawContext) {
        let palette = Theme.current.palette
        let eyebrow = stepsHeadingLayout(scale: scale)
        context.text(eyebrow, at: origin, color: palette.accentText)
        var y = origin.y + eyebrow.size.height
        let well = metrics.rowIconWell
        for step in steps {
            y += metrics.tv(28)
            let text = stepLayouts(step, scale: scale)
            let wellRect = Rect(x: origin.x, y: y, width: well, height: well)
            context.fill(wellRect, radius: metrics.radiusS, color: palette.accentTint)
            let symbol = metrics.symbolRow
            context.symbol(Symbol(step.symbol), in: Rect(x: wellRect.midX - symbol / 2, y: wellRect.midY - symbol / 2, width: symbol, height: symbol),
                           color: palette.accentText)
            let textX = origin.x + well + metrics.tv(24)
            context.text(text.title, at: Point(x: textX, y: y), color: palette.label)
            context.text(text.detail, at: Point(x: textX, y: y + text.title.size.height + metrics.tv(6)), color: palette.labelSecondary)
            y += max(well, text.title.size.height + metrics.tv(6) + text.detail.size.height)
        }
    }
}
