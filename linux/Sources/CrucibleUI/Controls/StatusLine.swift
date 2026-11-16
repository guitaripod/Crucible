import Foundation
import Kiln

/// A quiet status line with a spinner while something runs (`TVStatusRow`): "Connecting to Marcus-PC…", "Waiting for
/// approval…", or an error in the destructive tone. It takes no room while it has no text.
@MainActor
public final class StatusLineView: View {
    public enum Tone: Sendable {
        case neutral
        case error
    }

    public private(set) var text = ""
    private var isBusy = false
    private var tone = Tone.neutral
    private let spinner = SpinnerView()
    /// Centres the line in its width instead of starting it at the leading edge.
    public var isCentered = false { didSet { setNeedsLayout() } }
    /// The widest the text runs before it wraps.
    public var maxTextWidth: Float?

    public init() {
        super.init()
        addSubview(spinner)
        spinner.isHidden = true
    }

    /// Shows `text` (nothing for nil or empty), with the spinner while `busy`.
    public func show(_ newText: String?, busy: Bool = false, tone newTone: Tone = .neutral) {
        text = newText ?? ""
        isBusy = busy && !text.isEmpty
        tone = newTone
        spinner.isHidden = !isBusy
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var spinnerSide: Float { Theme.current.metrics.tv(36) }
    private var spacing: Float { Theme.current.metrics.tv(16) }

    /// The text wrapped to the room beside the spinner. A centred line is laid out in a box as wide as its longest line,
    /// so the spinner and the text centre together instead of the spinner sitting at the leading edge of a full-width box.
    private func layout(width: Float) -> TextLayout? {
        guard !text.isEmpty else { return nil }
        let room = width - (isBusy ? spinnerSide + spacing : 0)
        let scale = window?.scale ?? 1
        let natural = TextLayout(text, font: Theme.current.type.callout, maxWidth: max(1, min(room, maxTextWidth ?? room)), maxLines: 3,
                                 scale: scale)
        guard isCentered else { return natural }
        return TextLayout(text, font: Theme.current.type.callout, maxWidth: natural.size.width + 1, maxLines: 3, alignment: .center, scale: scale)
    }

    public override func sizeThatFits(_ size: Size) -> Size {
        guard let line = layout(width: size.width) else { return Size(width: size.width, height: 0) }
        return Size(width: size.width, height: max(line.size.height, isBusy ? spinnerSide : 0))
    }

    private func origin(of line: TextLayout) -> Float {
        let total = line.size.width + (isBusy ? spinnerSide + spacing : 0)
        return isCentered ? ((frame.width - total) / 2).rounded() : 0
    }

    public override func layoutSubviews() {
        guard let line = layout(width: frame.width), isBusy else { return }
        spinner.frame = Rect(x: origin(of: line), y: ((frame.height - spinnerSide) / 2).rounded(), width: spinnerSide, height: spinnerSide)
    }

    public override func draw(_ context: inout DrawContext) {
        guard let line = layout(width: frame.width) else { return }
        let palette = Theme.current.palette
        let x = origin(of: line) + (isBusy ? spinnerSide + spacing : 0)
        context.text(line, at: Point(x: x, y: ((frame.height - line.size.height) / 2).rounded()),
                     color: tone == .error ? palette.destructive : palette.labelSecondary)
    }
}
