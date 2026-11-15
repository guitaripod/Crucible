import Foundation
import Kiln

/// A one-line text field in a glass capsule (the desk's Search field): typing inserts at the caret, Backspace and Delete
/// remove a character or with Ctrl a word, Left and Right move the caret, Home and End jump, Ctrl+A selects everything so
/// the next key replaces it, Escape clears and then lets go. The caret blinks while the field has focus.
@MainActor
public final class TextFieldView: View {
    public var text = "" { didSet { if text != oldValue { caret = min(caret, text.count); setNeedsDisplay() } } }
    public var placeholder: String { didSet { setNeedsDisplay() } }
    public var symbol: Symbol?
    public var onChange: ((String) -> Void)?
    public var onSubmit: ((String) -> Void)?

    private var caret = 0
    private var selectAll = false
    private var blink: Float = 0
    private var focus = Animated(0)
    private var tone = GlassTone()

    public init(placeholder: String, symbol: Symbol? = "magnifyingglass") {
        self.placeholder = placeholder
        self.symbol = symbol
        super.init()
    }

    public override var canBecomeFocused: Bool { true }
    public override var cursor: Cursor { .text }
    public override var accessibilityLabel: String? { text.isEmpty ? placeholder : text }
    public override var overdraw: Float { Theme.current.metrics.tv(40) }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.primaryControlHeight)
    }

    /// Replaces the text and puts the caret at its end.
    public func setText(_ value: String, notify: Bool = true) {
        text = value
        caret = value.count
        selectAll = false
        if notify { onChange?(value) }
    }

    private func edit(_ change: (inout [Character], inout Int) -> Void) {
        var characters = Array(text)
        if selectAll {
            characters.removeAll()
            caret = 0
            selectAll = false
        }
        change(&characters, &caret)
        let updated = String(characters)
        blink = 0
        if updated != text {
            text = updated
            onChange?(updated)
        }
        setNeedsDisplay()
    }

    /// Where a word ends going left from `index`.
    private func wordStart(_ characters: [Character], from index: Int) -> Int {
        var position = index
        while position > 0, characters[position - 1].isWhitespace { position -= 1 }
        while position > 0, !characters[position - 1].isWhitespace { position -= 1 }
        return position
    }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        let control = event.modifiers.contains(.control)
        switch event.key {
        case .backspace:
            edit { characters, caret in
                guard caret > 0 else { return }
                let start = control ? wordStart(characters, from: caret) : caret - 1
                characters.removeSubrange(start..<caret)
                caret = start
            }
            return true
        case .delete:
            edit { characters, caret in
                guard caret < characters.count else { return }
                characters.remove(at: caret)
            }
            return true
        case .left where !text.isEmpty && caret > 0:
            caret = control ? wordStart(Array(text), from: caret) : caret - 1
            selectAll = false
            blink = 0
            setNeedsDisplay()
            return true
        case .right where caret < text.count:
            caret += 1
            selectAll = false
            blink = 0
            setNeedsDisplay()
            return true
        case .home:
            caret = 0
            setNeedsDisplay()
            return true
        case .end:
            caret = text.count
            setNeedsDisplay()
            return true
        case .return, .keypadEnter:
            onSubmit?(text)
            return true
        case .escape where !text.isEmpty:
            setText("")
            return true
        case Key.character("a") where control:
            selectAll = !text.isEmpty
            setNeedsDisplay()
            return true
        default:
            break
        }
        guard let typed = event.typedText else { return false }
        edit { characters, caret in
            characters.insert(contentsOf: Array(typed), at: caret)
            caret += typed.count
        }
        return true
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        focus.set(focused ? 1 : 0, animation: .focus)
        blink = 0
        startAnimating()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: true, reveal: false)
        caret = text.count
        return true
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [focus.advance(dt), tone.advance(dt)].contains(true)
        if isFocused {
            blink += dt
            setNeedsDisplay()
            return true
        }
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        guard let scale = window?.scale else { return }
        let rect = bounds
        if tone.update(context, rect: rect) { startAnimating() }
        GlassStyle.capsule(in: rect, light: Point(x: rect.midX, y: rect.minY - rect.height), press: 0.4 * focus.value, tone: tone.value, context: &context)
        if focus.value > 0.01 {
            context.stroke(rect, radius: rect.height / 2, width: max(metrics.tv(3), 1.5), color: theme.palette.accent.withAlpha(0.8 * focus.value))
        }
        let label = GlassStyle.label(tone: tone.value)
        let secondary = GlassStyle.secondaryLabel(tone: tone.value)
        var x = metrics.controlInset
        if let symbol {
            let side = theme.type.control.size * 1.1
            context.symbol(symbol, in: Rect(x: x, y: rect.midY - side / 2, width: side, height: side), color: secondary)
            x += side + metrics.tv(20)
        }
        let font = theme.type.searchField
        let available = rect.width - x - metrics.controlInset
        if text.isEmpty {
            let layout = TextLayout(placeholder, font: font, maxWidth: available, scale: scale)
            context.text(layout, at: Point(x: x, y: ((rect.height - layout.size.height) / 2 * scale).rounded() / scale), color: secondary)
        } else {
            let layout = TextLayout(text, font: font, scale: scale)
            let before = TextLayout(String(text.prefix(caret)), font: font, scale: scale).size.width
            let shift = max(0, before - available + metrics.tv(8))
            let y = ((rect.height - layout.size.height) / 2 * scale).rounded() / scale
            context.clipped(to: Rect(x: x, y: 0, width: available, height: rect.height)) { inner in
                if selectAll {
                    inner.fill(Rect(x: x - shift - 2, y: y, width: layout.size.width + 4, height: layout.size.height), radius: 4,
                               color: theme.palette.accent.withAlpha(0.35))
                }
                inner.text(layout, at: Point(x: x - shift, y: y), color: label)
            }
            if isFocused && Int(blink * 1.6) % 2 == 0 {
                context.fill(Rect(x: x + before - shift, y: y + 2, width: max(metrics.tv(3), 1.5), height: layout.size.height - 4), color: theme.palette.accent)
            }
            return
        }
        if isFocused && Int(blink * 1.6) % 2 == 0 {
            context.fill(Rect(x: x, y: rect.midY - font.size * 0.6, width: max(metrics.tv(3), 1.5), height: font.size * 1.2), color: theme.palette.accent)
        }
    }
}
