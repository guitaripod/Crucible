import Foundation
import Kiln

/// The A-Z index on a library's trailing edge (`TVAlphabetRail`): one focusable letter for every letter the library has
/// items for, over a strip where the artwork behind fades into the canvas. Selecting a letter reports it; the letter under
/// the grid's focus is lit in the accent.
@MainActor
public final class AlphabetRailView: View {
    public var onSelect: ((String) -> Void)?
    public private(set) var letters: [String] = []
    public var currentLetter: String? {
        didSet {
            guard currentLetter != oldValue else { return }
            buttons.values.forEach { $0.setNeedsDisplay() }
        }
    }

    private var buttons: [String: LetterButton] = [:]

    /// The strip the rail takes on the trailing edge, fade included.
    public static var width: Float { Theme.current.metrics.tv(96) }

    public func update(letters newLetters: [String]) {
        guard newLetters != letters else { return }
        letters = newLetters
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons = [:]
        for letter in newLetters {
            let button = LetterButton(letter: letter, rail: self)
            buttons[letter] = button
            addSubview(button)
        }
        setNeedsLayout()
    }

    /// The letter's button, for the owner to move the focus onto it.
    public func button(for letter: String) -> View? {
        buttons[letter]
    }

    fileprivate func select(_ letter: String) {
        onSelect?(letter)
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let height = min(metrics.tv(32), frame.height / Float(max(letters.count, 1)))
        let width = metrics.tv(56)
        var y = ((frame.height - height * Float(letters.count)) / 2).rounded()
        for letter in letters {
            buttons[letter]?.frame = Rect(x: frame.width - metrics.tv(12) - width, y: y, width: width, height: height)
            y += height
        }
    }

    /// Fades the canvas in under the letters from the content's edge, so cards and chips running up to the side margin
    /// stay whole and the letters stay readable over what scrolls past them in the margin.
    public override func draw(_ context: inout DrawContext) {
        let canvas = Theme.current.palette.canvas
        let edge = max(0, bounds.width - Theme.current.metrics.sideMargin)
        let fade = Rect(x: edge, y: 0, width: bounds.width - edge, height: bounds.height)
        context.gradient(fade, vertical: false, stops: [(0, canvas.withAlpha(0)), (0.5, canvas), (1, canvas)])
    }
}

/// One letter of the rail: a capsule under focus or the pointer, the accent when it is the letter the grid is at.
@MainActor
private final class LetterButton: View {
    let letter: String
    private weak var rail: AlphabetRailView?
    private var highlight = Animated(0)

    init(letter: String, rail: AlphabetRailView) {
        self.letter = letter
        self.rail = rail
        super.init()
    }

    override var canBecomeFocused: Bool { true }

    override var accessibilityLabel: String? {
        letter == "#" ? Strings.text("Jump to numbers and symbols") : "\(Strings.text("Jump to")) \(letter)"
    }

    private var isLit: Bool { (isFocused && (window?.isFocusVisible ?? false)) || isHovered }

    private func updateHighlight() {
        highlight.set(isLit ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func focusDidChange(focused: Bool, animated: Bool) { updateHighlight() }
    override func focusVisibilityDidChange(_ visible: Bool) { updateHighlight() }
    override func pointerEntered() { updateHighlight() }
    override func pointerExited() { updateHighlight() }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        button == .primary
    }

    override func pointerReleased(_ button: MouseButton, at point: Point, inside: Bool) {
        guard button == .primary, inside else { return }
        window?.focus.focus(self, animated: true, reveal: false)
        rail?.select(letter)
    }

    override func activate() {
        rail?.select(letter)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = highlight.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let palette = Theme.current.palette
        let font = Theme.current.type.caption1
        if highlight.value > 0.01 {
            context.fill(bounds, radius: bounds.height / 2, color: palette.focusFill.multipliedAlpha(highlight.value))
        }
        let resting = rail?.currentLetter == letter ? palette.accentText : palette.labelSecondary
        let color = highlight.value > 0.5 ? palette.onFocusFill : resting
        let layout = TextLayout(letter, font: font, scale: scale)
        context.text(layout, at: Point(x: ((bounds.width - layout.size.width) / 2).rounded(), y: ((bounds.height - layout.size.height) / 2).rounded()),
                     color: color)
    }
}
