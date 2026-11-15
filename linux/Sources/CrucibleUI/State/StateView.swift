import Foundation
import Kiln

/// The loading, empty and error screens (`TVStateView`): a spinner or a symbol, a title, a message and up to two buttons
/// in a centred column. A state with a button hands focus to it; one without holds focus on an invisible anchor, so the
/// keyboard never falls through to the tab bar while a screen loads.
@MainActor
public final class StateView: View {
    public enum State {
        case loading(title: String?)
        case empty(title: String, message: String?, symbol: Symbol, action: Action?)
        case error(title: String, message: String?, retryTitle: String, retry: () -> Void, secondary: Action? = nil)
    }

    public struct Action {
        public var title: String
        public var handler: () -> Void

        public init(title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    private var state: State = .loading(title: nil)
    private let spinner = SpinnerView()
    private let primary = ButtonView(style: .primary, title: nil)
    private let secondary = ButtonView(style: .glass, title: nil)
    private let anchor = FocusAnchorView()
    private var symbol: Symbol?
    private var title: String?
    private var message: String?

    public override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(spinner)
        addSubview(primary)
        addSubview(secondary)
        addSubview(anchor)
    }

    public override var preferredFocusView: View? { primary.isHidden ? anchor : primary }

    public func show(_ newState: State) {
        state = newState
        spinner.isHidden = true
        primary.isHidden = true
        secondary.isHidden = true
        symbol = nil
        title = nil
        message = nil
        switch newState {
        case .loading(let text):
            spinner.isHidden = false
            spinner.startAnimating()
            title = text
        case .empty(let text, let detail, let glyph, let action):
            symbol = glyph
            title = text
            message = detail
            if let action { configure(primary, action) }
        case .error(let text, let detail, let retryTitle, let retry, let other):
            symbol = "exclamationmark.triangle"
            title = text
            message = detail
            configure(primary, Action(title: retryTitle, handler: retry))
            if let other { configure(secondary, other) }
        }
        anchor.isHidden = !primary.isHidden
        setNeedsLayout()
        setNeedsDisplay()
        if containsFocus || window?.focusedView == nil { window?.focus.focus(self, animated: false) }
    }

    private func configure(_ button: ButtonView, _ action: Action) {
        button.title = action.title
        button.onPress = action.handler
        button.isHidden = false
    }

    private var rasterScale: Float { window?.scale ?? 1 }

    private struct Layout {
        var symbol: Rect?
        var title: (TextLayout, Point)?
        var message: (TextLayout, Point)?
        var buttons: Float
    }

    private func measure() -> Layout {
        let theme = Theme.current
        let metrics = theme.metrics
        let type = theme.type
        let width = min(metrics.wideColumn, frame.width - metrics.sideMargin * 2)
        var height: Float = 0
        let symbolSize = metrics.symbolState
        if symbol != nil || !spinner.isHidden { height += symbolSize + metrics.tv(32) }
        let titleLayout = title.map { TextLayout($0, font: type.title3, maxWidth: width, maxLines: 2, alignment: .center, scale: rasterScale) }
        let messageLayout = message.map { TextLayout($0, font: type.body, maxWidth: width, maxLines: 4, alignment: .center, scale: rasterScale) }
        if let titleLayout { height += titleLayout.size.height }
        if let messageLayout { height += metrics.tv(16) + messageLayout.size.height }
        let buttonsHeight: Float = primary.isHidden ? 0 : metrics.tv(48) + metrics.primaryControlHeight
        height += buttonsHeight
        var y = ((frame.height - height) / 2).rounded()
        var layout = Layout(buttons: 0)
        if symbol != nil || !spinner.isHidden {
            layout.symbol = Rect(x: (frame.width - symbolSize) / 2, y: y, width: symbolSize, height: symbolSize)
            y += symbolSize + metrics.tv(32)
        }
        if let titleLayout {
            layout.title = (titleLayout, Point(x: ((frame.width - titleLayout.size.width) / 2).rounded(), y: y))
            y += titleLayout.size.height
        }
        if let messageLayout {
            y += metrics.tv(16)
            layout.message = (messageLayout, Point(x: ((frame.width - messageLayout.size.width) / 2).rounded(), y: y))
            y += messageLayout.size.height
        }
        layout.buttons = y + metrics.tv(48)
        return layout
    }

    public override func layoutSubviews() {
        let layout = measure()
        if let symbolRect = layout.symbol { spinner.frame = symbolRect }
        anchor.frame = Rect(x: frame.width / 2 - 1, y: frame.height / 2 - 1, width: 2, height: 2)
        let buttons = [primary, secondary].filter { !$0.isHidden }
        let sizes = buttons.map { $0.sizeThatFits(Size(width: 600, height: 200)) }
        let gap = Theme.current.metrics.tv(32)
        var x = ((frame.width - sizes.reduce(0) { $0 + $1.width } - gap * Float(max(sizes.count - 1, 0))) / 2).rounded()
        for (button, size) in zip(buttons, sizes) {
            button.frame = Rect(x: x, y: layout.buttons, width: size.width, height: size.height)
            x += size.width + gap
        }
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let layout = measure()
        if let symbol, let rect = layout.symbol { context.symbol(symbol, in: rect, color: palette.labelTertiary) }
        if let (text, origin) = layout.title { context.text(text, at: origin, color: palette.label) }
        if let (text, origin) = layout.message { context.text(text, at: origin, color: palette.labelSecondary) }
    }
}

/// An invisible focusable point that holds focus while a screen has nothing else to focus (`TVFocusAnchorView`).
@MainActor
public final class FocusAnchorView: View {
    public override var canBecomeFocused: Bool { !isHidden }
    public override var isPointerInteractive: Bool { false }
}

/// The activity indicator: eight petals around a circle, the brightest one walking round once a second. It rests while it
/// or anything around it is hidden and carries on when shown again.
@MainActor
public final class SpinnerView: View {
    private var phase: Float = 0

    public override func didMoveToWindow() { startAnimating() }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        guard window != nil, !Animation.reduceMotion else { return false }
        phase = (phase + dt).truncatingRemainder(dividingBy: 1)
        setNeedsDisplay()
        return true
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let radius = min(bounds.width, bounds.height) * 0.36
        let dot = radius * 0.32
        let lead = Animation.reduceMotion ? 0 : Int(phase * 8)
        for index in 0..<8 {
            let angle = Float(index) / 8 * 2 * .pi - .pi / 2
            let center = Point(x: bounds.midX + cos(angle) * radius, y: bounds.midY + sin(angle) * radius)
            let age = Float((lead - index + 8) % 8)
            let alpha = 1 - age / 8 * 0.8
            context.fill(Rect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot), radius: dot / 2,
                         color: palette.labelSecondary.multipliedAlpha(alpha))
        }
    }
}

/// Grey placeholders of a screen's cards that pulse softly while it loads (`TVSkeletonView`).
@MainActor
public final class SkeletonShelfView: View {
    public var style: CardStyle
    public var count = 8
    private var pulse: Float = 0

    public init(style: CardStyle) {
        self.style = style
        super.init()
    }

    public override func didMoveToWindow() { startAnimating() }

    public override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        return Size(width: size.width, height: metrics.shelfHeaderHeight + metrics.shelfTopInset + style.itemSize.height + metrics.shelfBottomInset)
    }

    public override func advanceAnimations(_ dt: Float) -> Bool {
        guard window != nil, !Animation.reduceMotion else { return false }
        pulse = (pulse + dt / (Durations.skeletonPulse * 2)).truncatingRemainder(dividingBy: 1)
        setNeedsDisplay()
        return true
    }

    public override func draw(_ context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let opacity = Animation.reduceMotion ? 1 : 0.775 + 0.225 * cos(pulse * 2 * .pi)
        let headerY = metrics.shelfHeaderHeight - metrics.sectionSpacing - metrics.tv(36)
        context.fill(Rect(x: metrics.sideMargin, y: headerY, width: metrics.tv(320), height: metrics.tv(36)), radius: metrics.radiusXS,
                     color: palette.surfaceRaised.multipliedAlpha(opacity))
        var x = metrics.sideMargin
        let top = metrics.shelfHeaderHeight + metrics.shelfTopInset
        for _ in 0..<count where x < frame.width {
            let art = Rect(x: x, y: top, width: style.artworkSize.width, height: style.artworkSize.height)
            context.fill(art, radius: style.shape == .circle ? art.width / 2 : metrics.cardCornerRadius, color: palette.surfaceRaised.multipliedAlpha(opacity))
            context.fill(Rect(x: x, y: art.maxY + metrics.captionSpacing, width: style.itemWidth * 0.7, height: metrics.tv(26)), radius: metrics.radiusXS,
                         color: palette.surfaceRaised.multipliedAlpha(opacity * 0.8))
            x += style.itemWidth + metrics.gutter
        }
    }
}

/// The title of a pushed screen (`TVScreenTitleView`): title2 bold with an optional summary beside it and a description
/// below, starting at the tab bar's clearance.
@MainActor
public final class ScreenTitleView: View {
    public var title: String { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    public var summary: String? { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    public var detail: String? { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }
    /// Lines the title up with a centred column of this width (a settings list) instead of the screen's margin.
    public var columnWidth: Float? { didSet { setNeedsDisplay() } }

    public init(title: String, summary: String? = nil, detail: String? = nil) {
        self.title = title
        self.summary = summary
        self.detail = detail
        super.init()
    }

    private var rasterScale: Float { window?.scale ?? 1 }

    private var leading: Float {
        let metrics = Theme.current.metrics
        guard let columnWidth else { return metrics.sideMargin }
        let width = min(columnWidth, frame.width - metrics.sideMargin * 2)
        return ((frame.width - width) / 2).rounded() + metrics.rowInset
    }

    private func layouts(width: Float) -> (TextLayout, TextLayout?, TextLayout?) {
        let type = Theme.current.type
        let metrics = Theme.current.metrics
        let column = width - leading - metrics.sideMargin
        let titleLayout = TextLayout(title, font: type.screenTitle, maxWidth: column, scale: rasterScale)
        let summaryLayout = summary.map { TextLayout($0, font: type.screenSummary, maxWidth: column - titleLayout.size.width - metrics.tv(32), scale: rasterScale) }
        let detailLayout = detail.map { TextLayout($0, font: type.screenDetail, maxWidth: min(column, metrics.messageColumn), maxLines: 3, scale: rasterScale) }
        return (titleLayout, summaryLayout, detailLayout)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        let (title, _, detail) = layouts(width: size.width)
        let metrics = Theme.current.metrics
        let titleHeight = self.title.isEmpty ? 0 : title.size.height
        return Size(width: size.width, height: titleHeight + (detail.map { (titleHeight > 0 ? metrics.tv(16) : 0) + $0.size.height } ?? 0) + metrics.tv(24))
    }

    public override func draw(_ context: inout DrawContext) {
        let palette = Theme.current.palette
        let metrics = Theme.current.metrics
        let (title, summary, detail) = layouts(width: frame.width)
        let x = leading
        let titleHeight = self.title.isEmpty ? 0 : title.size.height
        if !self.title.isEmpty { context.text(title, at: Point(x: x, y: 0), color: palette.label) }
        if let summary {
            let baselineShift = title.baseline - summary.baseline
            context.text(summary, at: Point(x: x + title.size.width + metrics.tv(32), y: baselineShift), color: palette.labelSecondary)
        }
        if let detail {
            context.text(detail, at: Point(x: x, y: titleHeight + (titleHeight > 0 ? metrics.tv(16) : 0)), color: palette.labelSecondary)
        }
    }
}
