import Foundation
import Kiln

/// A one-line text field in a glass capsule (the desk's Search field): typing inserts at the caret, Backspace and Delete
/// remove a character or with Ctrl a word, Left and Right move the caret, Home and End jump, Ctrl+A selects everything so
/// the next key replaces it, Ctrl+C, Ctrl+X and Ctrl+V copy, cut and paste, Escape clears and then lets go. The caret
/// blinks while the field has focus. The desktop's input method composes into it (text-input-v3): the composition shows
/// underlined at the caret until the input method commits it.
@MainActor
public final class TextFieldView: View, TextInputClient {
    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            caret = min(caret, text.count)
            setNeedsDisplay()
            reportTextInput()
        }
    }
    public var placeholder: String { didSet { setNeedsDisplay() } }
    /// Shows a dot for every character instead of the text (a PIN or a password).
    public var isSecure = false {
        didSet {
            setNeedsDisplay()
            reportTextInput()
        }
    }

    /// What the field draws for its text.
    private var shownText: String { isSecure ? String(repeating: "•", count: text.count) : text }
    public var symbol: Symbol?
    public var onChange: ((String) -> Void)?
    public var onSubmit: ((String) -> Void)?

    private var caret = 0 { didSet { if caret != oldValue { reportTextInput() } } }
    private var selectAll = false { didSet { if selectAll != oldValue { reportTextInput() } } }
    /// The input method's composition, shown at the caret, with its cursor as UTF-8 offsets into it (nil hides the caret).
    private var composition: (text: String, cursor: Range<Int>?)?
    private var textInputReported = false
    private var blinkStart = Window.now()
    private var caretFlip: DispatchWorkItem?
    private var focus = Animated(0)
    private var tone = GlassTone()

    public init(placeholder: String, symbol: Symbol? = "magnifyingglass") {
        self.placeholder = placeholder
        self.symbol = symbol
        super.init()
    }

    public override var canBecomeFocused: Bool { true }
    public override var cursor: Cursor { .text }
    public override var accessibilityLabel: String? { text.isEmpty || isSecure ? placeholder : text }
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
        restartBlink()
        if updated != text {
            text = updated
            onChange?(updated)
        }
        setNeedsDisplay()
    }

    /// Copy and Cut take the whole text once Ctrl+A selected it (never a secure field's) and otherwise pass the key on, so
    /// the window copies text selected elsewhere; Paste inserts at the caret, or replaces the selection, with line breaks
    /// turned into spaces.
    private func perform(_ command: ClipboardCommand) -> Bool {
        switch command {
        case .copy, .cut:
            guard selectAll, !isSecure else { return false }
            window?.copy(text)
            if command == .cut { edit { _, _ in } }
        case .paste:
            guard let pasted = window?.pasteboardText().map(TextFieldView.oneLine), !pasted.isEmpty else { return true }
            edit { characters, caret in
                characters.insert(contentsOf: Array(pasted), at: caret)
                caret += pasted.count
            }
        }
        return true
    }

    /// Pasted text as one line: surrounding whitespace dropped, breaks and tabs inside it made spaces.
    private static func oneLine(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    public var textInputState: TextInputState {
        let utf8Caret = String(text.prefix(caret)).utf8.count
        return TextInputState(text: text, cursor: selectAll ? text.utf8.count : utf8Caret, anchor: selectAll ? 0 : utf8Caret,
                              caret: caretRect(scale: window?.scale ?? 1), purpose: isSecure ? .password : .normal)
    }

    /// The protocol's order: the composition goes, the deletion and the commit edit the text (a selection gives way to
    /// them, or to a new composition), and the new composition shows at the caret.
    public func applyTextInput(_ event: TextInputEvent) {
        composition = nil
        if event.commit != nil || event.deleteBefore > 0 || event.deleteAfter > 0 || (event.preedit != nil && selectAll) {
            edit { characters, caret in
                let result = event.applied(to: String(characters), caret: caret)
                characters = Array(result.text)
                caret = result.caret
            }
        }
        composition = event.preedit.map { ($0, event.preeditCursor) }
        restartBlink()
        setNeedsDisplay()
    }

    /// Tells the window the text or caret changed, once for everything one event changed, so the input method follows.
    private func reportTextInput() {
        guard !textInputReported else { return }
        textInputReported = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.textInputReported = false
                self.window?.textInputChanged(self)
            }
        }
    }

    /// What the field draws: its text with the composition at the caret, and where the caret stands in it.
    private var displayed: (text: String, caret: Int?) {
        let shown = shownText
        guard let composition else { return (shown, caret) }
        let composed = String(shown.prefix(caret)) + composition.text + String(shown.dropFirst(caret))
        guard let cursor = composition.cursor else { return (composed, nil) }
        let inside = TextInputEvent.characterIndex(in: Array(composition.text), atUTF8: cursor.lowerBound, roundingUp: false)
        return (composed, caret + inside)
    }

    /// Where the text starts, how far it is shifted left to keep the caret in view, and its top.
    private func textGeometry(scale: Float) -> (x: Float, available: Float, shift: Float, caretX: Float, top: Float, height: Float) {
        let theme = Theme.current
        let metrics = theme.metrics
        var x = metrics.controlInset
        if symbol != nil { x += theme.type.control.size * 1.1 + metrics.tv(20) }
        let available = bounds.width - x - metrics.controlInset
        let font = theme.type.searchField
        let shown = displayed
        let layout = TextLayout(shown.text.isEmpty ? " " : shown.text, font: font, scale: scale)
        let before = TextLayout(String(shown.text.prefix(shown.caret ?? caret)), font: font, scale: scale).size.width
        let shift = max(0, before - available + metrics.tv(8))
        let top = ((bounds.height - layout.size.height) / 2 * scale).rounded() / scale
        return (x, available, shift, x + before - shift, top, layout.size.height)
    }

    /// The caret's rectangle in the field's points, for the input method's candidate window.
    private func caretRect(scale: Float) -> Rect {
        let geometry = textGeometry(scale: scale)
        return Rect(x: geometry.caretX, y: geometry.top, width: max(Theme.current.metrics.tv(3), 1.5), height: geometry.height)
    }

    /// Where a word ends going left from `index`.
    private func wordStart(_ characters: [Character], from index: Int) -> Int {
        var position = index
        while position > 0, characters[position - 1].isWhitespace { position -= 1 }
        while position > 0, !characters[position - 1].isWhitespace { position -= 1 }
        return position
    }

    /// Where a word ends going right from `index`.
    private func wordEnd(_ characters: [Character], from index: Int) -> Int {
        var position = index
        while position < characters.count, characters[position].isWhitespace { position += 1 }
        while position < characters.count, !characters[position].isWhitespace { position += 1 }
        return position
    }

    public override func keyPressed(_ event: KeyEvent) -> Bool {
        if let command = event.clipboardCommand { return perform(command) }
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
                let end = control ? wordEnd(characters, from: caret) : caret + 1
                characters.removeSubrange(caret..<end)
            }
            return true
        case .left where !text.isEmpty && caret > 0:
            caret = control ? wordStart(Array(text), from: caret) : caret - 1
            selectAll = false
            restartBlink()
            setNeedsDisplay()
            return true
        case .right where caret < text.count:
            caret = control ? wordEnd(Array(text), from: caret) : caret + 1
            selectAll = false
            restartBlink()
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
        if !focused { composition = nil }
        focus.set(focused ? 1 : 0, animation: .focus)
        restartBlink()
        startAnimating()
    }

    /// The caret shows solid again (after a key or a focus change) and blinks from now.
    private func restartBlink() {
        blinkStart = Window.now()
        scheduleCaretFlip()
    }

    /// Whether the caret is in the shown half of its blink.
    private var caretShown: Bool { isFocused && Int((Window.now() - blinkStart) * 1.6) % 2 == 0 }

    /// Redraws at the caret's next blink, not every frame in between, and stops once the field lets go of focus.
    private func scheduleCaretFlip() {
        caretFlip?.cancel()
        let elapsed = Window.now() - blinkStart
        let next = (floor(elapsed * 1.6) + 1) / 1.6 - elapsed
        let flip = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isFocused else { return }
                self.setNeedsDisplay()
                self.scheduleCaretFlip()
            }
        }
        caretFlip = flip
        DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: flip)
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: true, reveal: false)
        caret = text.count
        return true
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = [focus.advance(dt), tone.advance(dt)].contains(true)
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
        let shown = displayed
        if shown.text.isEmpty {
            let layout = TextLayout(placeholder, font: font, maxWidth: available, scale: scale)
            context.text(layout, at: Point(x: x, y: ((rect.height - layout.size.height) / 2 * scale).rounded() / scale), color: secondary)
        } else {
            let layout = TextLayout(shown.text, font: font, scale: scale)
            let geometry = textGeometry(scale: scale)
            let y = geometry.top
            context.clipped(to: Rect(x: x, y: 0, width: available, height: rect.height)) { inner in
                if selectAll {
                    inner.fill(Rect(x: x - geometry.shift - 2, y: y, width: layout.size.width + 4, height: layout.size.height), radius: 4,
                               color: theme.palette.accent.withAlpha(0.35))
                }
                inner.text(layout, at: Point(x: x - geometry.shift, y: y), color: label)
                if let composition {
                    drawCompositionUnderline(composition.text, in: shown.text, font: font, origin: Point(x: x - geometry.shift, y: y),
                                             height: layout.size.height, color: label, scale: scale, context: &inner)
                }
            }
            if caretShown && shown.caret != nil {
                context.fill(Rect(x: geometry.caretX, y: y + 2, width: max(metrics.tv(3), 1.5), height: layout.size.height - 4), color: theme.palette.accent)
            }
            return
        }
        if caretShown {
            context.fill(Rect(x: x, y: rect.midY - font.size * 0.6, width: max(metrics.tv(3), 1.5), height: font.size * 1.2), color: theme.palette.accent)
        }
    }

    /// The line under the composition, as input methods mark text that is not typed yet.
    private func drawCompositionUnderline(_ composed: String, in shown: String, font: Font, origin: Point, height: Float, color: Color,
                                          scale: Float, context: inout DrawContext) {
        let start = TextLayout(String(shown.prefix(caret)), font: font, scale: scale).size.width
        let width = TextLayout(composed, font: font, scale: scale).size.width
        let thickness = max(Theme.current.metrics.tv(3), 1.5)
        context.fill(Rect(x: origin.x + start, y: origin.y + height - thickness, width: width, height: thickness), radius: thickness / 2,
                     color: color.withAlpha(0.8))
    }
}
