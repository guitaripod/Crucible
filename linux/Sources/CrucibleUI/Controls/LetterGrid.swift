import Foundation
import Kiln

/// The on-screen keyboard of Search on a couch (the tvOS search keyboard), for typing with a gamepad: the letters in a row,
/// then the digits with Space, Delete and Clear, each key a focus stop that grows white under the focus.
@MainActor
public final class LetterGridView: View {
    public enum Press: Equatable, Sendable {
        case text(String), delete, clear
    }

    public var onPress: ((Press) -> Void)?
    private var rows: [[KeyView]] = []

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        let letters = "abcdefghijklmnopqrstuvwxyz".map { KeyView(press: .text(String($0)), title: String($0)) }
        let digits = "1234567890".map { KeyView(press: .text(String($0)), title: String($0)) }
        let tools = [KeyView(press: .text(" "), title: Strings.lookup("Space"), wide: true),
                     KeyView(press: .delete, symbol: "delete.left", spoken: Strings.lookup("Delete")),
                     KeyView(press: .clear, title: Strings.lookup("Clear"), wide: true)]
        rows = [letters, digits + tools]
        for key in rows.joined() {
            key.onPress = { [weak self] press in self?.onPress?(press) }
            addSubview(key)
        }
    }

    public override var preferredFocusView: View? { rows.first?.first }
    public override var remembersFocus: Bool { true }

    private var keyHeight: Float { Theme.current.metrics.tv(72) }
    private var gap: Float { Theme.current.metrics.tv(10) }

    public override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: keyHeight * Float(rows.count) + gap * Float(max(rows.count - 1, 0)))
    }

    /// Each row centred; a key is as wide as the letters row allows, up to the tvOS size, and the wide keys hold their words.
    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let letters = Float(rows.first?.count ?? 1)
        let keyWidth = min(metrics.tv(64), (bounds.width - gap * (letters - 1)) / letters).rounded(.down)
        for (index, row) in rows.enumerated() {
            let widths = row.map { $0.isWide ? max(keyWidth * 2, $0.preferredWidth(scale: window?.scale ?? 1)) : keyWidth }
            let total = widths.reduce(0, +) + gap * Float(row.count - 1)
            var x = ((bounds.width - total) / 2).rounded()
            let y = Float(index) * (keyHeight + gap)
            for (key, width) in zip(row, widths) {
                key.frame = Rect(x: x, y: y, width: width, height: keyHeight)
                x += width + gap
            }
        }
    }
}

/// One key of the letter grid.
@MainActor
private final class KeyView: View {
    let press: LetterGridView.Press
    let isWide: Bool
    var onPress: ((LetterGridView.Press) -> Void)?
    private let title: String?
    private let symbol: Symbol?
    private let spoken: String?
    private var lift = Animated(0)

    init(press: LetterGridView.Press, title: String? = nil, symbol: Symbol? = nil, spoken: String? = nil, wide: Bool = false) {
        self.press = press
        self.title = title
        self.symbol = symbol
        self.spoken = spoken
        isWide = wide
        super.init()
    }

    override var canBecomeFocused: Bool { true }
    override var accessibilityLabel: String? { spoken ?? title }
    override var overdraw: Float { Theme.current.metrics.tv(16) }

    func preferredWidth(scale: Float) -> Float {
        guard let title else { return 0 }
        return TextLayout(title, font: Theme.current.type.control, scale: scale).size.width + Theme.current.metrics.tv(48)
    }

    override func activate() {
        onPress?(press)
    }

    override func focusDidChange(focused: Bool, animated: Bool) {
        lift.set(focused ? 1 : 0, animation: animated ? .focus : nil)
        startAnimating()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = lift.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool {
        guard button == .primary else { return false }
        window?.focus.focus(self, animated: true, reveal: false)
        onPress?(press)
        return true
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let palette = theme.palette
        let grow = 1 + 0.12 * lift.value
        let rect = Rect(x: bounds.midX - bounds.width * grow / 2, y: bounds.midY - bounds.height * grow / 2, width: bounds.width * grow,
                        height: bounds.height * grow)
        let radius = theme.metrics.radiusS
        if lift.value > 0.01 { context.shadow(rect, radius: radius, blur: theme.metrics.tv(18), offsetY: theme.metrics.tv(8), opacity: 0.35 * lift.value) }
        context.fill(rect, radius: radius, color: palette.surfaceRaised.mixed(with: .white, amount: lift.value))
        let ink = palette.label.mixed(with: .black, amount: lift.value)
        if let symbol {
            let side = theme.type.control.size * 1.2
            context.symbol(symbol, in: Rect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), color: ink)
        } else if let title {
            let layout = TextLayout(title, font: Font(size: theme.type.control.size * (isWide ? 1 : 1.15), weight: .semibold), scale: scale)
            context.text(layout, at: Point(x: (rect.midX - layout.size.width / 2).rounded(), y: (rect.midY - layout.size.height / 2).rounded()), color: ink)
        }
    }
}
