import Foundation
import Kiln

/// A multi-line text editor (a comment or a review): text wraps to the width and the editor grows with it up to
/// `maximumLines`, then scrolls to keep the caret in view. Typing inserts at the caret, Return starts a new line and
/// Ctrl+Return submits, Backspace and Delete remove a character or with Ctrl a word, the arrows move the caret by
/// character, word (Ctrl) and visual line, Home and End go to the line's ends (with Ctrl, the text's), Ctrl+A selects
/// everything so the next key replaces it, and Ctrl+C, Ctrl+X and Ctrl+V copy, cut and paste. Up on the first line and Down on the last let the focus move on.
@MainActor
public final class TextEditorView: View {
    public private(set) var text = ""
    public var placeholder: String { didSet { setNeedsDisplay() } }
    public var onChange: ((String) -> Void)?
    /// Ctrl+Return.
    public var onSubmit: (() -> Void)?
    public var minimumLines = 5 { didSet { superview?.setNeedsLayout() } }
    public var maximumLines = 12 { didSet { superview?.setNeedsLayout() } }

    private var caret = 0
    private var stickyX: Float?
    private var selectAll = false
    private var scrollY: Float = 0
    private var blinkStart = Window.now()
    private var caretFlip: DispatchWorkItem?
    private var focus = Animated(0)

    public init(placeholder: String) {
        self.placeholder = placeholder
        super.init()
    }

    public override var canBecomeFocused: Bool { true }
    public override var cursor: Cursor { .text }
    public override var accessibilityLabel: String? { text.isEmpty ? placeholder : text }

    /// Replaces the text and puts the caret at its end.
    public func setText(_ value: String, notify: Bool = true) {
        text = value
        caret = value.count
        selectAll = false
        stickyX = nil
        superview?.setNeedsLayout()
        setNeedsDisplay()
        if notify { onChange?(value) }
    }

    // MARK: Layout

    private var metrics: Metrics { Theme.current.metrics }
    private var font: Font { Theme.current.type.callout }
    private var inset: Float { metrics.tv(28) }
    private var lineHeight: Float { (font.size * 1.25).rounded() }
    private var contentWidth: Float { max(1, frame.width - inset * 2) }

    private func layout(width: Float) -> TextLayout {
        TextLayout(text.isEmpty ? " " : text, font: font, maxWidth: width, maxLines: 0, scale: window?.scale ?? 1)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let lines = text.isEmpty ? 1 : layout(width: max(1, size.width - inset * 2)).lineCount
        let shown = min(max(lines, minimumLines), maximumLines)
        return Size(width: size.width, height: Float(shown) * lineHeight + inset * 2)
    }

    private var visibleHeight: Float { frame.height - inset * 2 }

    // MARK: Caret

    private func utf8Offset(_ characterOffset: Int) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(max(characterOffset, 0), text.count))
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    private func characterOffset(ofUTF8 byteOffset: Int) -> Int {
        var index = text.utf8.index(text.utf8.startIndex, offsetBy: min(max(byteOffset, 0), text.utf8.count))
        while String.Index(index, within: text) == nil, index > text.startIndex { index = text.utf8.index(before: index) }
        return text.distance(from: text.startIndex, to: index)
    }

    private func caretRect(_ laidOut: TextLayout) -> Rect {
        guard !text.isEmpty else { return Rect(x: 0, y: 0, width: 0, height: lineHeight) }
        return laidOut.caret(atUTF8: utf8Offset(caret))
    }

    /// Scrolls so the caret's line shows.
    private func revealCaret() {
        let rect = caretRect(layout(width: contentWidth))
        if rect.minY < scrollY { scrollY = rect.minY }
        if rect.maxY > scrollY + visibleHeight { scrollY = rect.maxY - visibleHeight }
        scrollY = max(0, scrollY)
    }

    /// The caret one visual line up or down, keeping the column it started from; nil past the first or last line.
    private func lineMove(_ direction: Float) -> Int? {
        let laidOut = layout(width: contentWidth)
        let rect = caretRect(laidOut)
        let x = stickyX ?? rect.minX
        stickyX = x
        let y = direction < 0 ? rect.minY - lineHeight / 2 : rect.maxY + lineHeight / 2
        guard y >= 0, y <= laidOut.size.height else { return nil }
        return characterOffset(ofUTF8: laidOut.utf8Index(at: Point(x: x, y: y)))
    }

    /// The start or end of the caret's visual line.
    private func lineEdge(end: Bool) -> Int {
        let laidOut = layout(width: contentWidth)
        let rect = caretRect(laidOut)
        let found = characterOffset(ofUTF8: laidOut.utf8Index(at: Point(x: end ? contentWidth + 100 : 0, y: rect.midY)))
        guard end, found > 0, found <= text.count else { return found }
        let character = text[text.index(text.startIndex, offsetBy: found - 1)]
        return character == "\n" ? found - 1 : found
    }

    // MARK: Editing

    private func edit(_ change: (inout [Character], inout Int) -> Void) {
        var characters = Array(text)
        if selectAll {
            characters.removeAll()
            caret = 0
            selectAll = false
        }
        change(&characters, &caret)
        let updated = String(characters)
        stickyX = nil
        if updated != text {
            text = updated
            onChange?(updated)
            superview?.setNeedsLayout()
        }
        moved()
    }

    private func moved() {
        revealCaret()
        restartBlink()
        setNeedsDisplay()
    }

    private func wordStart(_ characters: [Character], from index: Int) -> Int {
        var position = index
        while position > 0, characters[position - 1].isWhitespace { position -= 1 }
        while position > 0, !characters[position - 1].isWhitespace { position -= 1 }
        return position
    }

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
        case .return, .keypadEnter:
            if control {
                onSubmit?()
            } else {
                edit { characters, caret in
                    characters.insert("\n", at: caret)
                    caret += 1
                }
            }
            return true
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
        case .left where caret > 0:
            caret = control ? wordStart(Array(text), from: caret) : caret - 1
            settle()
            return true
        case .right where caret < text.count:
            caret = control ? wordEnd(Array(text), from: caret) : caret + 1
            settle()
            return true
        case .up:
            guard let moved = lineMove(-1) else {
                guard caret > 0 else { return false }
                caret = 0
                settle()
                return true
            }
            caret = moved
            settleKeepingColumn()
            return true
        case .down:
            guard let moved = lineMove(1) else {
                guard caret < text.count else { return false }
                caret = text.count
                settle()
                return true
            }
            caret = moved
            settleKeepingColumn()
            return true
        case .home:
            caret = control ? 0 : lineEdge(end: false)
            settle()
            return true
        case .end:
            caret = control ? text.count : lineEdge(end: true)
            settle()
            return true
        case Key.character("a") where control:
            selectAll = !text.isEmpty
            setNeedsDisplay()
            return true
        default:
            break
        }
        guard let typed = event.typedText, !typed.isEmpty, !control else { return false }
        edit { characters, caret in
            characters.insert(contentsOf: Array(typed), at: caret)
            caret += typed.count
        }
        return true
    }

    /// Copy and Cut take the whole text once Ctrl+A selected it and otherwise pass the key on, so the window copies text
    /// selected elsewhere; Paste inserts at the caret, or replaces the selection, with Windows line ends made plain.
    private func perform(_ command: ClipboardCommand) -> Bool {
        switch command {
        case .copy, .cut:
            guard selectAll else { return false }
            window?.copy(text)
            if command == .cut { edit { _, _ in } }
        case .paste:
            guard let pasted = window?.pasteboardText()?.replacingOccurrences(of: "\r\n", with: "\n"), !pasted.isEmpty else { return true }
            edit { characters, caret in
                characters.insert(contentsOf: Array(pasted), at: caret)
                caret += pasted.count
            }
        }
        return true
    }

    /// The caret moved sideways: the column it keeps for Up and Down is the new one.
    private func settle() {
        stickyX = nil
        selectAll = false
        moved()
    }

    private func settleKeepingColumn() {
        selectAll = false
        moved()
    }

    public override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: true, reveal: false)
        if !text.isEmpty {
            let laidOut = layout(width: contentWidth)
            caret = characterOffset(ofUTF8: laidOut.utf8Index(at: Point(x: point.x - inset, y: point.y - inset + scrollY)))
        }
        settle()
        return true
    }

    public override func scrolled(_ event: ScrollEvent) -> Bool {
        let total = layout(width: contentWidth).size.height
        guard total > visibleHeight else { return false }
        scrollY = min(max(0, scrollY + event.dy), total - visibleHeight)
        setNeedsDisplay()
        return true
    }

    // MARK: Focus and blink

    public override func focusDidChange(focused: Bool, animated: Bool) {
        focus.set(focused ? 1 : 0, animation: .focus)
        restartBlink()
        startAnimating()
    }

    private func restartBlink() {
        blinkStart = Window.now()
        scheduleCaretFlip()
    }

    private var caretShown: Bool { isFocused && Int((Window.now() - blinkStart) * 1.6) % 2 == 0 }

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

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = focus.advance(dt)
        setNeedsDisplay()
        return moving
    }

    // MARK: Drawing

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let radius = metrics.radiusM
        context.fill(bounds, radius: radius, color: palette.surface)
        context.stroke(bounds, radius: radius, width: 1, color: palette.separator)
        if focus.value > 0.01 {
            context.stroke(bounds, radius: radius, width: max(metrics.tv(3), 1.5), color: palette.accent.withAlpha(0.8 * focus.value))
        }
        guard let scale = window?.scale else { return }
        let area = Rect(x: inset, y: inset, width: contentWidth, height: visibleHeight)
        if text.isEmpty {
            let hint = TextLayout(placeholder, font: font, maxWidth: area.width, maxLines: 0, scale: scale)
            context.text(hint, at: area.origin, color: palette.labelTertiary)
            if caretShown { context.fill(Rect(x: area.x, y: area.y, width: max(metrics.tv(3), 1.5), height: lineHeight), color: palette.accent) }
            return
        }
        let laidOut = layout(width: area.width)
        let origin = Point(x: area.x, y: area.y - scrollY)
        context.clipped(to: area) { inner in
            if selectAll {
                inner.fill(Rect(x: origin.x - 2, y: origin.y, width: laidOut.size.width + 4, height: laidOut.size.height), radius: 4,
                           color: palette.accent.withAlpha(0.35))
            }
            inner.text(laidOut, at: origin, color: palette.label)
            if caretShown {
                let rect = caretRect(laidOut)
                inner.fill(Rect(x: origin.x + rect.minX, y: origin.y + rect.minY, width: max(metrics.tv(3), 1.5), height: rect.height), color: palette.accent)
            }
        }
    }
}
