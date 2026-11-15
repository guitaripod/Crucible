import Foundation
import Kiln

/// A title's synopsis under its hero (`TVDetailSynopsisCell`): up to four lines, and More when it runs longer, which
/// opens the whole text.
@MainActor
public final class SynopsisView: View {
    public var onMore: (() -> Void)?
    private let more = ButtonView(style: .plain, title: Strings.lookup("More"))
    public var text: String { didSet { if text != oldValue { setNeedsLayout(); superview?.setNeedsLayout(); setNeedsDisplay() } } }

    public init(text: String) {
        self.text = text
        super.init()
        more.onPress = { [weak self] in self?.onMore?() }
        addSubview(more)
    }

    private var column: Float { Theme.current.metrics.heroTextColumn }

    private func layout(scale: Float) -> TextLayout {
        TextLayout(text, font: Theme.current.type.body, maxWidth: column, maxLines: 4, scale: scale)
    }

    private var isTruncated: Bool { layout(scale: window?.scale ?? 1).isTruncated }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let textHeight = layout(scale: window?.scale ?? 1).size.height
        let moreHeight = isTruncated ? metrics.tv(12) + more.sizeThatFits(size).height : 0
        return Size(width: size.width, height: textHeight + moreHeight + metrics.tv(28))
    }

    public override func layoutSubviews() {
        let metrics = Theme.current.metrics
        more.isHidden = !isTruncated
        let size = more.sizeThatFits(bounds.size)
        more.frame = Rect(x: metrics.sideMargin - metrics.plainControlInset, y: layout(scale: window?.scale ?? 1).size.height + metrics.tv(12),
                          width: size.width, height: size.height)
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        context.text(layout(scale: scale), at: Point(x: Theme.current.metrics.sideMargin, y: 0), color: Theme.current.palette.labelSecondary)
    }
}

/// The Information panel of a title page (`TVInformationSurface`): its facts (studio, directors, dates, file, audio) in a
/// two-column grid under a heading. It takes focus, so the keyboard can scroll down to it.
@MainActor
public final class InformationView: View {
    public var facts: [(key: String, value: String)] = [] { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    private var focus = Animated(0)

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
    }

    public override var canBecomeFocused: Bool { !facts.isEmpty }
    public override var accessibilityLabel: String? { facts.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }

    private var heading: String { Strings.lookup("Information") }
    private var inset: Float { Theme.current.metrics.tv(36) }
    private var columnGap: Float { Theme.current.metrics.tv(48) }

    private func panelWidth(_ width: Float) -> Float { width - Theme.current.metrics.sideMargin * 2 }

    private func cells(width: Float, scale: Float) -> [(key: TextLayout, value: TextLayout)] {
        let type = Theme.current.type
        let column = (panelWidth(width) - inset * 2 - columnGap) / 2
        return facts.map { fact in
            (TextLayout(fact.key.uppercased(), font: type.caption1, maxWidth: column, scale: scale),
             TextLayout(fact.value, font: type.body, maxWidth: column, maxLines: 4, scale: scale))
        }
    }

    private func rowHeights(_ cells: [(key: TextLayout, value: TextLayout)]) -> [Float] {
        let spacing = Theme.current.metrics.tv(6)
        return stride(from: 0, to: cells.count, by: 2).map { start in
            cells[start..<min(start + 2, cells.count)].map { $0.key.size.height + spacing + $0.value.size.height }.max() ?? 0
        }
    }

    private func headingLayout(scale: Float) -> TextLayout {
        TextLayout(heading, font: Theme.current.type.headline, scale: scale)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        guard !facts.isEmpty else { return Size(width: size.width, height: 0) }
        let metrics = Theme.current.metrics
        let scale = window?.scale ?? 1
        let rows = rowHeights(cells(width: size.width, scale: scale))
        let panel = inset * 2 + rows.reduce(0, +) + Float(max(rows.count - 1, 0)) * metrics.tv(28)
        return Size(width: size.width, height: headingLayout(scale: scale).size.height + metrics.tv(24) + panel + metrics.sectionSpacing)
    }

    public override func focusDidChange(focused: Bool, animated: Bool) {
        focus.set(focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = focus.advance(dt)
        setNeedsDisplay()
        return moving
    }

    public override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale, !facts.isEmpty else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let title = headingLayout(scale: scale)
        context.text(title, at: Point(x: metrics.sideMargin, y: 0), color: palette.label)
        let laid = cells(width: bounds.width, scale: scale)
        let rows = rowHeights(laid)
        let top = title.size.height + metrics.tv(24)
        let panel = Rect(x: metrics.sideMargin, y: top, width: panelWidth(bounds.width),
                         height: inset * 2 + rows.reduce(0, +) + Float(max(rows.count - 1, 0)) * metrics.tv(28))
        context.fill(panel, radius: metrics.radiusM, color: palette.surface.mixed(with: palette.surfaceRaised, amount: focus.value))
        let column = (panel.width - inset * 2 - columnGap) / 2
        var y = panel.y + inset
        for (row, height) in rows.enumerated() {
            for side in 0..<2 {
                let index = row * 2 + side
                guard index < laid.count else { continue }
                let x = panel.x + inset + Float(side) * (column + columnGap)
                context.text(laid[index].key, at: Point(x: x, y: y), color: palette.labelTertiary)
                context.text(laid[index].value, at: Point(x: x, y: y + laid[index].key.size.height + metrics.tv(6)), color: palette.label)
            }
            y += height + metrics.tv(28)
        }
    }
}
