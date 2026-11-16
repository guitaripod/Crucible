import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// What the context column of Sports Research shows for the focused row (`TVSportsStageContent`): an eyebrow, a heading,
/// a poster with a file name becoming its title, a paragraph, and a few lines with symbols.
struct SportsStageContent {
    struct Art {
        var file: String
        var title: String
        var words: SportsPosterWords?
        var posterPath: String?
        var kind: SportsKind = .sports
    }

    struct Line {
        var symbol: Symbol
        var tint: Color
        var title: String
        var detail: String?
        var emphasized = false
    }

    var eyebrow: String?
    var eyebrowTint: Color?
    var heading: String?
    var art: Art?
    var body: String?
    var lines: [Line] = []
    /// While research runs: when its timer reads zero, so the eyebrow counts the seconds between reports.
    var runningSince: Date?
}

/// The context column of Sports Research (`TVSportsStage`): a raised panel whose content follows the focus, fading in for a
/// new subject and updating in place for the same one, so the live research ticks without flashing. Lines the panel
/// cannot fit whole are left out rather than cut through.
@MainActor
final class SportsStageView: View {
    private var content = SportsStageContent()
    private var key: String?
    private let poster = SportsPosterView()
    private var appear = Animated(1)
    private var ticker: Task<Void, Never>?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(poster)
    }

    isolated deinit {
        ticker?.cancel()
    }

    func show(_ content: SportsStageContent, key: String) {
        let isNew = key != self.key
        self.content = content
        self.key = key
        if let art = content.art { poster.show(path: art.posterPath, words: art.words, kind: art.kind) }
        poster.isHidden = content.art == nil
        if isNew, window != nil {
            appear.set(0, animation: nil)
            appear.set(1, animation: .timed(duration: 0.3, curve: .easeInOut))
            startAnimating()
        }
        restartTicker()
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// Tall enough for the content it shows, and never shorter than a step's checks need, so moving between rows does not
    /// make the column jump.
    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = size.width - inset * 2
        let scale = window?.scale ?? 1
        let parts = layouts(width: width, scale: scale)
        var height = inset * 2 + headerHeight(parts)
        if content.art != nil { height += artHeight(parts) + gap }
        if let body = parts.body { height += body.size.height + gap }
        height += linesHeight(width: width, scale: scale)
        return Size(width: size.width, height: max(height, metrics.tv(820)).rounded(.up))
    }

    private func linesHeight(width: Float, scale: Float) -> Float {
        let theme = Theme.current
        let metrics = theme.metrics
        let textWidth = width - metrics.tv(30) - metrics.tv(16)
        return content.lines.reduce(Float(0)) { total, line in
            let title = TextLayout(line.title, font: line.emphasized ? theme.type.cardTitle : theme.type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: scale)
            let detail = line.detail.flatMap { $0.isEmpty ? nil : TextLayout($0, font: theme.type.cardSubtitle, maxWidth: textWidth, maxLines: 3, scale: scale) }
            return total + title.size.height + (detail.map { $0.size.height + metrics.tv(4) } ?? 0) + metrics.tv(14)
        }
    }

    override func didMoveToWindow() {
        restartTicker()
    }

    /// Redraws once a second while research runs and the stage is on screen, so its eyebrow counts.
    private func restartTicker() {
        ticker?.cancel()
        ticker = nil
        guard window != nil, content.runningSince != nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.setNeedsDisplay()
            }
        }
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = appear.advance(dt)
        setNeedsDisplay()
        return moving
    }

    private var inset: Float { Theme.current.metrics.tv(36) }
    private var gap: Float { Theme.current.metrics.tv(20) }
    private var posterSize: Size { Size(width: Theme.current.metrics.tv(180), height: Theme.current.metrics.tv(270)) }

    private var eyebrowText: String? {
        guard let base = content.eyebrow?.uppercased() else { return nil }
        guard let since = content.runningSince else { return base }
        return "\(base) · \(SportsCopy.duration(Int(Date().timeIntervalSince(since))))"
    }

    private struct Layouts {
        var eyebrow: TextLayout?
        var heading: TextLayout?
        var file: TextLayout?
        var title: TextLayout?
        var body: TextLayout?
    }

    private func layouts(width: Float, scale: Float) -> Layouts {
        let type = Theme.current.type
        let artText = width - posterSize.width - gap
        return Layouts(
            eyebrow: eyebrowText.map { TextLayout($0, font: type.eyebrow, maxWidth: width, maxLines: 1, scale: scale) },
            heading: content.heading.map { TextLayout($0, font: Font(size: type.title3.size, weight: .bold), maxWidth: width, maxLines: 3, scale: scale) },
            file: content.art.map { TextLayout($0.file, font: type.cardSubtitle, maxWidth: artText, maxLines: 3, scale: scale) },
            title: content.art.map { TextLayout($0.title, font: Font(size: type.headline.size, weight: .bold), maxWidth: artText, maxLines: 5, scale: scale) },
            body: content.body.flatMap { $0.isEmpty ? nil : TextLayout($0, font: type.cardSubtitle, maxWidth: width, maxLines: 6, scale: scale) }
        )
    }

    /// The poster and the change beside it: as tall as the taller of the two.
    private func artHeight(_ parts: Layouts) -> Float {
        guard let file = parts.file, let title = parts.title else { return 0 }
        let metrics = Theme.current.metrics
        return max(posterSize.height, file.size.height + metrics.tv(52) + title.size.height)
    }

    private func headerHeight(_ parts: Layouts) -> Float {
        var y: Float = 0
        if let eyebrow = parts.eyebrow { y += eyebrow.size.height + Theme.current.metrics.tv(8) }
        if let heading = parts.heading { y += heading.size.height + gap }
        return y
    }

    override func layoutSubviews() {
        let parts = layouts(width: bounds.width - inset * 2, scale: window?.scale ?? 1)
        poster.frame = Rect(x: inset, y: inset + headerHeight(parts), width: posterSize.width, height: posterSize.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let palette = theme.palette
        let metrics = theme.metrics
        context.fill(bounds, radius: metrics.radiusL, color: palette.surfaceRaised)
        let width = bounds.width - inset * 2
        let parts = layouts(width: width, scale: scale)
        context.faded(appear.value) { faded in
            var y = inset
            if let eyebrow = parts.eyebrow {
                faded.text(eyebrow, at: Point(x: inset, y: y), color: content.eyebrowTint ?? palette.accentText)
                y += eyebrow.size.height + metrics.tv(8)
            }
            if let heading = parts.heading {
                faded.text(heading, at: Point(x: inset, y: y), color: palette.label)
                y += heading.size.height + gap
            }
            if let file = parts.file, let title = parts.title {
                drawChange(file: file, title: title, top: y, context: &faded)
                y += artHeight(parts) + gap
            }
            if let body = parts.body {
                faded.text(body, at: Point(x: inset, y: y), color: palette.labelSecondary)
                y += body.size.height + gap
            }
            drawLines(from: y, width: width, scale: scale, context: &faded)
        }
    }

    /// The release name in small type, an arrow down, and the clean title beside the poster.
    private func drawChange(file: TextLayout, title: TextLayout, top: Float, context: inout DrawContext) {
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let x = inset + posterSize.width + gap
        let arrow = metrics.tv(28)
        let height = file.size.height + metrics.tv(12) + arrow + metrics.tv(12) + title.size.height
        var y = top + max(0, (posterSize.height - height) / 2).rounded()
        context.text(file, at: Point(x: x, y: y), color: palette.labelTertiary)
        y += file.size.height + metrics.tv(12)
        context.symbol("arrow.down", in: Rect(x: x, y: y, width: arrow, height: arrow), color: palette.accent)
        y += arrow + metrics.tv(12)
        context.text(title, at: Point(x: x, y: y), color: palette.label)
    }

    private func drawLines(from top: Float, width: Float, scale: Float, context: inout DrawContext) {
        let theme = Theme.current
        let metrics = theme.metrics
        let icon = metrics.tv(30)
        var y = top
        for line in content.lines {
            let textWidth = width - icon - metrics.tv(16)
            let title = TextLayout(line.title, font: line.emphasized ? theme.type.cardTitle : theme.type.cardSubtitle, maxWidth: textWidth, maxLines: 2, scale: scale)
            let detail = line.detail.flatMap { $0.isEmpty ? nil : TextLayout($0, font: theme.type.cardSubtitle, maxWidth: textWidth, maxLines: 3, scale: scale) }
            let height = title.size.height + (detail.map { $0.size.height + metrics.tv(4) } ?? 0)
            guard y + height <= bounds.height - inset else { return }
            context.symbol(line.symbol, in: Rect(x: inset, y: y + metrics.tv(2), width: icon, height: icon), color: line.tint)
            let x = inset + icon + metrics.tv(16)
            context.text(title, at: Point(x: x, y: y), color: line.emphasized ? theme.palette.label : theme.palette.labelSecondary)
            if let detail { context.text(detail, at: Point(x: x, y: y + title.size.height + metrics.tv(4)), color: theme.palette.labelTertiary) }
            y += height + metrics.tv(14)
        }
    }
}

/// A sports file's poster (`SportsPosterView`): a drawn poster with the kind's symbol and the event's words at its foot,
/// under the server's artwork, which fades in over it once it arrives.
@MainActor
final class SportsPosterView: View {
    private let artwork = ArtworkView()
    private var words: SportsPosterWords?
    private var kind: SportsKind = .sports

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        artwork.cornerRadius = Theme.current.metrics.radiusS
        artwork.fillsUntilLoaded = false
        addSubview(artwork)
    }

    func show(path: String?, words: SportsPosterWords?, kind: SportsKind) {
        self.words = words
        self.kind = kind
        artwork.source = path.map { .path($0, .poster) }
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        artwork.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        context.fill(bounds, radius: metrics.radiusS, color: theme.palette.surfaceHigh)
        context.stroke(bounds, radius: metrics.radiusS, width: 1, color: theme.palette.separator)
        let side = bounds.width * 0.36
        context.symbol(Symbol(kind.posterSymbol), in: Rect(x: bounds.midX - side / 2, y: bounds.height * 0.3 - side / 2, width: side, height: side),
                       color: theme.palette.labelTertiary)
        guard let words, bounds.width >= 70 else { return }
        let inner = bounds.width - metrics.tv(24)
        let caption = TextLayout(words.caption, font: theme.type.cardTitle, maxWidth: inner, maxLines: 3, scale: scale)
        let eyebrow = TextLayout(words.eyebrow.uppercased(), font: theme.type.eyebrow, maxWidth: inner, maxLines: 2, scale: scale)
        var y = bounds.height - metrics.tv(14) - caption.size.height
        context.text(caption, at: Point(x: metrics.tv(12), y: y), color: theme.palette.label)
        y -= eyebrow.size.height + metrics.tv(4)
        context.text(eyebrow, at: Point(x: metrics.tv(12), y: y), color: theme.palette.accentText)
    }
}
