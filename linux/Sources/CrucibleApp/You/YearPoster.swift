import CrucibleCore
import CrucibleStats
import CrucibleUI
import Foundation
import Kiln

/// The two shapes of the Year in Review poster (`WrappedShareCardRenderer.Format`): a 9:16 story with the full telling
/// and a square for feeds, in the poster's own pixels.
enum YearPosterFormat: CaseIterable {
    case story, square

    var size: Size {
        switch self {
        case .story: return Size(width: 1080, height: 1920)
        case .square: return Size(width: 1080, height: 1080)
        }
    }

    var title: String {
        switch self {
        case .story: return String(localized: "Story")
        case .square: return String(localized: "Square")
        }
    }
}

/// Everything the poster draws (`WrappedShareContent`), resolved before drawing: the page's facts, the top titles'
/// posters by rank order, the lead poster blurred for the wash across the top, and the line along the foot.
@MainActor
struct YearPosterContent {
    let facts: StatsShareFacts
    let posters: [Int: Texture]
    let wash: Texture?
    let footer: String

    /// The facts of `page` with the top three posters fetched through the window's image store at the poster's size.
    static func load(page: StatsPage, source: StatsSource, window: Window) async -> YearPosterContent {
        let facts = StatsShareFacts(page: page, time: StatsTime())
        var posters: [Int: Texture] = [:]
        if let images = window.images {
            for (index, title) in facts.titles.prefix(3).enumerated() {
                guard let path = title.thumb, let url = Artwork.pipeline?.url(path: path, kind: .poster, pixelWidth: 480) else { continue }
                if let texture = await images.load(ImageRequest(url: url, pixelWidth: 480, pixelHeight: 720)) { posters[index] = texture }
            }
        }
        let wash = posters[0].flatMap { window.gpu.blurred($0) }
        return YearPosterContent(facts: facts, posters: posters, wash: wash, footer: footer(for: source))
    }

    /// The poster's foot: only the Plex server, or with Everything chosen, the plays Trakt holds from everywhere else too.
    static func footer(for source: StatsSource) -> String {
        switch source {
        case .plex: return String(localized: "Watched on my own Plex server")
        case .everything:
            return String(localized: "Watched on Plex and everywhere else, via Trakt",
                          comment: "Foot of the shared statistics poster when it counts the plays Trakt recorded outside Plex too")
        }
    }
}

/// The poster drawn into the view's bounds at any size: every measure is in the poster's pixels and scales with the
/// view's width, so the preview on screen and the 1080 pixel export are the same drawing with text set natively for each.
@MainActor
final class YearPosterView: View {
    let content: YearPosterContent
    var format: YearPosterFormat { didSet { if format != oldValue { setNeedsDisplay() } } }

    init(content: YearPosterContent, format: YearPosterFormat) {
        self.content = content
        self.format = format
        super.init()
    }

    override func draw(_ context: inout DrawContext) {
        let size = format.size
        guard bounds.width > 0 else { return }
        let canvas = PosterCanvas(context: context, unit: bounds.width / size.width, rasterScale: window?.scale ?? 1, size: size)
        switch format {
        case .story: StoryComposition(canvas: canvas, content: content).draw()
        case .square: SquareComposition(canvas: canvas, content: content).draw()
        }
    }

    override var accessibilityRole: AccessibilityRole { .image }
    override var accessibilityLabel: String? { content.facts.summary }
}

/// The poster's fixed palette (`WrappedInk`): a warm near-black ground with the ember accent, the same whatever the
/// app's appearance. Translucent inks carry the alphas the phone blends in sRGB, converted for Kiln's linear blending.
@MainActor
private enum PosterInk {
    static let canvas = Color(hex: 0x0E0D0C)
    static let label = Color(hex: 0xF6F3EF)
    static let secondary = Color(hex: 0xF6F3EF, srgbAlpha: 0.70)
    static let tertiary = Color(hex: 0xF6F3EF, srgbAlpha: 0.46)
    static let accent = Color(hex: 0xFF9F0A)
    static let accentBright = Color(hex: 0xFFB340)
    static let hairline = Color(hex: 0xFFFFFF, srgbAlpha: 0.14)
    static let well = Color(hex: 0xFFFFFF, srgbAlpha: 0.07)
    static let badgeInk = Color(hex: 0x1B1204)

    /// `color` at the opacity that lands on the ground where the phone's sRGB blending at `alpha` does: over black the
    /// sRGB result is the colour times `alpha` before decoding, which linear blending reaches at `alpha` to the 2.2.
    static func overGround(_ color: Color, _ alpha: Float) -> Color {
        color.withAlpha(Float(pow(Double(alpha), 2.2)))
    }

    /// The heat ramp in its dark appearance (`StatsStyle.heatColor`); level 0 is an empty day.
    static func heat(_ level: Int) -> Color {
        switch max(0, min(5, level)) {
        case 0: return Color(hex: 0x3A3734)
        case 1: return overGround(accent, 0.28)
        case 2: return overGround(accent, 0.46)
        case 3: return overGround(accent, 0.66)
        case 4: return overGround(accent, 0.86)
        default: return accentBright
        }
    }
}

/// The poster's drawing primitives (`WrappedShareCanvas`) in poster pixels, mapped onto the view by `unit`.
@MainActor
private struct PosterCanvas {
    let context: DrawContext
    let unit: Float
    let rasterScale: Float
    let size: Size

    func rect(_ x: Float, _ y: Float, _ width: Float, _ height: Float) -> Rect {
        Rect(x: x * unit, y: y * unit, width: width * unit, height: height * unit)
    }

    func point(_ x: Float, _ y: Float) -> Point {
        Point(x: x * unit, y: y * unit)
    }

    /// Text in Inter at a poster size, laid out within `width` poster pixels (0 for one unbounded line).
    func text(_ string: String, size: Float, weight: Font.Weight, kern: Float = 0, width: Float = 0, lines: Int = 1,
              alignment: TextStyle.Alignment = .leading) -> TextLayout {
        var font = Font(size: size * unit, weight: weight)
        font.letterSpacing = kern * unit
        return TextLayout(string, font: font, maxWidth: width * unit, maxLines: lines, alignment: alignment, scale: rasterScale)
    }

    func width(of layout: TextLayout) -> Float { layout.size.width / unit }
    func height(of layout: TextLayout) -> Float { layout.size.height / unit }
    func baseline(of layout: TextLayout) -> Float { layout.baseline / unit }

    /// Draws `layout` with its top left at (`x`, `y`), centred across `centredIn` poster pixels when given, on whole pixels.
    @discardableResult
    func draw(_ layout: TextLayout, x: Float, y: Float, centredIn width: Float? = nil, color: Color) -> Float {
        var left = x * unit
        if let width { left += max(0, (width * unit - layout.size.width) / 2) }
        context.text(layout, at: snapped(Point(x: left, y: y * unit)), color: color)
        return height(of: layout)
    }

    private func snapped(_ point: Point) -> Point {
        let scale = max(rasterScale, 0.01)
        return Point(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    func fillBackground() {
        context.fill(rect(0, 0, size.width, size.height), color: PosterInk.canvas)
    }

    /// The lead poster, blurred and dimmed across the top so the page takes its colour from the title that defined the
    /// period, fading into the ground.
    func drawWash(_ wash: Texture?, height: Float) {
        guard let wash else { return }
        let band = rect(0, 0, size.width, height)
        context.image(wash, in: band, srgb: true)
        context.fill(band, color: PosterInk.canvas.withSRGBAlpha(0.42))
        context.gradient(band, vertical: true, stops: [
            (0, PosterInk.canvas.withAlpha(0)),
            (0.62, PosterInk.canvas.withSRGBAlpha(0.85)),
            (1, PosterInk.canvas),
        ])
    }

    func drawGlow(center x: Float, _ y: Float, radius: Float, alpha: Float) {
        context.glow(in: rect(0, 0, size.width, size.height), radius: 0, center: point(x, y), glowRadius: radius * unit,
                     color: PosterInk.overGround(PosterInk.accent, alpha))
    }

    /// The largest size from `base` down to two thirds of it at which the widest of `strings` fits `width`, so a row of
    /// labels with one long word gets a little smaller as a whole instead of ending in an ellipsis.
    func fittedSize(_ base: Float, weight: Font.Weight, strings: [String], kern: Float, width: Float) -> Float {
        let smallest = (base * 2 / 3).rounded(.up)
        var size = base
        while size > smallest {
            let widest = strings.map { self.width(of: text($0, size: size, weight: weight, kern: kern)) }.max() ?? 0
            if widest <= width { return size }
            size -= 1
        }
        return smallest
    }

    func drawWordmark(x: Float, y: Float, markSize: Float, textSize: Float) {
        context.symbol(Symbol("flame.fill"), in: rect(x, y, markSize, markSize), color: PosterInk.accent)
        let word = text("CRUCIBLE", size: textSize, weight: .heavy, kern: 6)
        draw(word, x: x + markSize + 14, y: y + (markSize - height(of: word)) / 2 + 2, color: PosterInk.label)
    }

    func drawPeriodPill(_ period: String, trailingX: Float, top: Float, height: Float, fontSize: Float) {
        let label = text(period, size: fontSize, weight: .heavy, kern: 3)
        let width = self.width(of: label) + height
        let pill = rect(trailingX - width, top, width, height)
        context.fill(pill, radius: pill.height / 2, color: PosterInk.overGround(PosterInk.accent, 0.16))
        context.stroke(pill, radius: pill.height / 2, width: 2 * unit, color: PosterInk.overGround(PosterInk.accent, 0.9))
        draw(label, x: trailingX - width, y: top + (height - self.height(of: label)) / 2, centredIn: width, color: PosterInk.accentBright)
    }

    /// A hero figure that shrinks to fit `maxWidth`, its unit on the same baseline; returns the baseline.
    @discardableResult
    func drawHeroFigure(_ value: String, unit heroUnit: String, x: Float, y: Float, maxWidth: Float, fontSize: Float) -> Float {
        var point = fontSize
        func layouts(_ point: Float) -> (value: TextLayout, unit: TextLayout) {
            (text(value, size: point, weight: .heavy, kern: -point * 0.02), text(heroUnit, size: point * 0.2, weight: .bold))
        }
        var drawn = layouts(point)
        while width(of: drawn.value) + point * 0.12 + width(of: drawn.unit) > maxWidth, point > 80 {
            point -= 6
            drawn = layouts(point)
        }
        draw(drawn.value, x: x, y: y, color: PosterInk.label)
        let baseline = y + baseline(of: drawn.value)
        draw(drawn.unit, x: x + width(of: drawn.value) + point * 0.12, y: baseline - self.baseline(of: drawn.unit), color: PosterInk.accentBright)
        return baseline
    }

    func drawHairline(x: Float, y: Float, width: Float) {
        context.fill(rect(x, y - 1, width, 2), color: PosterInk.hairline)
    }

    func drawVerticalHairline(x: Float, y: Float, height: Float) {
        context.fill(rect(x - 1, y, 2, height), color: PosterInk.hairline)
    }

    func drawSectionLabel(_ label: String, x: Float, y: Float, width: Float, fontSize: Float) {
        let layout = text(label, size: fontSize, weight: .heavy, kern: 5)
        draw(layout, x: x, y: y, color: PosterInk.accent)
        let lineStart = x + self.width(of: layout) + 28
        drawHairline(x: lineStart, y: y + height(of: layout) / 2, width: max(0, x + width - lineStart))
    }

    func chipWidth(_ label: String, height: Float, fontSize: Float) -> Float {
        width(of: text(label, size: fontSize, weight: .semibold)) + height * 0.9
    }

    func drawChip(_ label: String, x: Float, y: Float, height: Float, fontSize: Float) {
        let layout = text(label, size: fontSize, weight: .semibold)
        let width = self.width(of: layout) + height * 0.9
        context.fill(rect(x, y, width, height), radius: height / 2 * unit, color: PosterInk.well)
        draw(layout, x: x, y: y + (height - self.height(of: layout)) / 2, centredIn: width, color: PosterInk.secondary)
    }

    func drawPoster(_ texture: Texture?, placeholder: Symbol, rank: Int, in frame: Rect, radius: Float, badgeSize: Float, highlighted: Bool) {
        let area = rect(frame.x, frame.y, frame.width, frame.height)
        let corner = radius * unit
        context.shadow(area, radius: corner, blur: 44 * unit, offsetY: 18 * unit, opacity: 0.55)
        context.fill(area, radius: corner, color: PosterInk.canvas)
        if let texture {
            context.image(texture, in: area, radius: corner)
        } else {
            context.fill(area, radius: corner, color: PosterInk.well)
            let side = frame.width * 0.32
            context.symbol(placeholder, in: rect(frame.midX - side / 2, frame.midY - side / 2, side, side), color: PosterInk.tertiary)
        }
        context.stroke(area, radius: corner, width: (highlighted ? 5 : 2) * unit, color: highlighted ? PosterInk.accent : PosterInk.hairline)
        drawRankBadge(rank, x: frame.minX + badgeSize * 0.3, y: frame.minY + badgeSize * 0.3, size: badgeSize, highlighted: highlighted)
    }

    private func drawRankBadge(_ rank: Int, x: Float, y: Float, size: Float, highlighted: Bool) {
        let circle = rect(x, y, size, size)
        context.fill(circle, radius: circle.width / 2, color: highlighted ? PosterInk.accent : Color(hex: 0x000000, srgbAlpha: 0.62))
        if !highlighted { context.stroke(circle, radius: circle.width / 2, width: 2 * unit, color: Color(hex: 0xFFFFFF, srgbAlpha: 0.28)) }
        let number = text("\(rank)", size: size * 0.56, weight: .heavy)
        draw(number, x: x, y: y + (size - height(of: number)) / 2, centredIn: size, color: highlighted ? PosterInk.badgeInk : PosterInk.label)
    }

    func drawHeatmap(_ model: HeatmapModel, x: Float, y: Float, width: Float, height: Float) {
        guard model.columns > 0 else { return }
        let stride = min(width / Float(model.columns), height / 7)
        let edge = stride * 0.8
        var levels: [Int: Int] = [:]
        for cell in model.cells { levels[cell.column * 7 + cell.row] = cell.level }
        let left = x + (width - stride * Float(model.columns)) / 2
        for column in 0..<model.columns {
            for row in 0..<7 where model.firstDayEpoch + column * 7 + row <= model.lastDayEpoch {
                let cell = rect(left + Float(column) * stride, y + Float(row) * stride, edge, edge)
                context.fill(cell, radius: edge * 0.24 * unit, color: PosterInk.heat(levels[column * 7 + row] ?? 0))
            }
        }
    }
}

/// The story: wordmark and period, the hero figure, the figures row, the top three posters, then genres and the heat
/// map filling what room is left above the foot.
@MainActor
private struct StoryComposition {
    let canvas: PosterCanvas
    let content: YearPosterContent

    private let margin: Float = 84
    private var width: Float { canvas.size.width }
    private var contentWidth: Float { width - margin * 2 }
    private var facts: StatsShareFacts { content.facts }

    func draw() {
        canvas.fillBackground()
        canvas.drawWash(content.wash, height: 1180)
        canvas.drawGlow(center: width * 0.9, 300, radius: 760, alpha: 0.34)
        canvas.drawGlow(center: 0, canvas.size.height, radius: 800, alpha: 0.16)
        canvas.drawWordmark(x: margin, y: 88, markSize: 56, textSize: 36)
        canvas.drawPeriodPill(facts.period, trailingX: width - margin, top: 90, height: 52, fontSize: 26)
        let detailBottom = drawHero()
        let figuresBottom = drawFigures(top: detailBottom + 56)
        let titlesBottom = drawTitles(top: figuresBottom + 64)
        let footerTop = canvas.size.height - 96
        let footer = canvas.text(content.footer, size: 26, weight: .semibold, kern: 1, width: contentWidth, alignment: .center)
        canvas.draw(footer, x: margin, y: footerTop, centredIn: contentWidth, color: PosterInk.tertiary)
        drawTail(titlesBottom: titlesBottom, footerTop: footerTop)
    }

    private func drawHero() -> Float {
        let eyebrow = canvas.text(facts.eyebrow.uppercased(), size: 34, weight: .heavy, kern: 5, width: contentWidth)
        canvas.draw(eyebrow, x: margin, y: 218, color: PosterInk.accent)
        let baseline = canvas.drawHeroFigure(facts.heroValue, unit: facts.heroUnit, x: margin - 8, y: 262, maxWidth: contentWidth, fontSize: 320)
        let detail = canvas.text(facts.heroDetail, size: 40, weight: .semibold, width: contentWidth)
        let top = baseline + 40
        return top + canvas.draw(detail, x: margin, y: top, color: PosterInk.secondary)
    }

    private func drawFigures(top: Float) -> Float {
        let height: Float = 132
        canvas.drawHairline(x: margin, y: top, width: contentWidth)
        canvas.drawHairline(x: margin, y: top + height, width: contentWidth)
        let figures = facts.figures
        let columnWidth = contentWidth / Float(max(figures.count, 1))
        let labels = figures.map { $0.label.uppercased() }
        let labelSize = canvas.fittedSize(22, weight: .bold, strings: labels, kern: 2.5, width: columnWidth - 12)
        let fullLabelHeight = canvas.height(of: canvas.text("A", size: 22, weight: .bold))
        for (index, figure) in figures.enumerated() {
            let x = margin + columnWidth * Float(index)
            let value = canvas.text(figure.value, size: 60, weight: .heavy, kern: -1, width: columnWidth, alignment: .center)
            let valueHeight = canvas.draw(value, x: x, y: top + 20, centredIn: columnWidth, color: PosterInk.label)
            let label = canvas.text(labels[index], size: labelSize, weight: .bold, kern: 2.5, width: columnWidth, alignment: .center)
            canvas.draw(label, x: x, y: top + 20 + valueHeight - 2 + (fullLabelHeight - canvas.height(of: label)) / 2, centredIn: columnWidth,
                        color: PosterInk.tertiary)
            if index > 0 { canvas.drawVerticalHairline(x: x, y: top + 28, height: height - 56) }
        }
        return top + height
    }

    private func drawTitles(top: Float) -> Float {
        guard !facts.titles.isEmpty else { return top }
        canvas.drawSectionLabel(String(localized: "MOST WATCHED"), x: margin, y: top, width: contentWidth, fontSize: 28)
        let gap: Float = 28
        let posterWidth = ((contentWidth - gap * 2) / 3).rounded(.down)
        let posterHeight = (posterWidth * 1.5).rounded(.down)
        let posterTop = top + 58
        var bottom = posterTop
        for (index, title) in facts.titles.prefix(3).enumerated() {
            let x = margin + Float(index) * (posterWidth + gap)
            let frame = Rect(x: x, y: posterTop, width: posterWidth, height: posterHeight)
            canvas.drawPoster(content.posters[index], placeholder: Symbol(title.placeholderSymbol), rank: title.rank, in: frame, radius: 26,
                              badgeSize: 68, highlighted: index == 0)
            let name = canvas.text(title.name, size: 32, weight: .bold, width: posterWidth, lines: 2)
            let nameHeight = canvas.draw(name, x: x, y: frame.maxY + 22, color: PosterInk.label)
            let captionY = frame.maxY + 22 + nameHeight + 6
            let caption = canvas.text(title.caption, size: 26, weight: .medium, width: posterWidth)
            bottom = max(bottom, captionY + canvas.draw(caption, x: x, y: captionY, color: PosterInk.secondary))
        }
        return bottom
    }

    /// Genres and the heat map fill whatever room the titles leave, anchored above the foot.
    private func drawTail(titlesBottom: Float, footerTop: Float) {
        var cursor = footerTop - 40
        if let heatmap = facts.heatmap, heatmap.columns > 0 {
            let height = contentWidth / Float(heatmap.columns) * 7
            cursor -= height
            canvas.drawHeatmap(heatmap, x: margin, y: cursor, width: contentWidth, height: height)
            cursor -= 40
        }
        let chipHeight: Float = 58
        let chipsTop = cursor - chipHeight
        guard !facts.genres.isEmpty, chipsTop > titlesBottom + 24 else { return }
        var x = margin
        for genre in facts.genres.prefix(4) {
            let width = canvas.chipWidth(genre, height: chipHeight, fontSize: 28)
            guard x + width <= self.width - margin else { break }
            canvas.drawChip(genre, x: x, y: chipsTop, height: chipHeight, fontSize: 28)
            x += width + 16
        }
    }
}

/// The square: the hero and four figures on the left, the top three as rows on the right with genres under them, and
/// the heat map as a band above the foot.
@MainActor
private struct SquareComposition {
    let canvas: PosterCanvas
    let content: YearPosterContent

    private let margin: Float = 64
    private let leftWidth: Float = 470
    private var width: Float { canvas.size.width }
    private var contentWidth: Float { width - margin * 2 }
    private var facts: StatsShareFacts { content.facts }

    func draw() {
        canvas.fillBackground()
        canvas.drawWash(content.wash, height: 760)
        canvas.drawGlow(center: width * 0.92, 120, radius: 620, alpha: 0.32)
        canvas.drawGlow(center: 0, canvas.size.height, radius: 560, alpha: 0.14)
        canvas.drawWordmark(x: margin, y: 54, markSize: 44, textSize: 30)
        canvas.drawPeriodPill(facts.period, trailingX: width - margin, top: 54, height: 44, fontSize: 22)
        let detailBottom = drawHero()
        drawFigures(top: detailBottom + 40)
        let titlesLeft = margin + leftWidth + 56
        drawTitles(left: titlesLeft, top: 168)
        drawGenres(left: titlesLeft, top: 168 + 3 * 196 + 8)
        drawHeatmapBand()
        let footer = canvas.text(content.footer, size: 22, weight: .semibold, kern: 1, width: contentWidth, alignment: .center)
        canvas.draw(footer, x: margin, y: canvas.size.height - 62, centredIn: contentWidth, color: PosterInk.tertiary)
    }

    private func drawHero() -> Float {
        let eyebrow = canvas.text(facts.eyebrow.uppercased(), size: 26, weight: .heavy, kern: 4, width: leftWidth + 60)
        canvas.draw(eyebrow, x: margin, y: 160, color: PosterInk.accent)
        let baseline = canvas.drawHeroFigure(facts.heroValue, unit: facts.heroUnit, x: margin - 6, y: 192, maxWidth: leftWidth, fontSize: 230)
        let detail = canvas.text(facts.heroDetail, size: 30, weight: .semibold, width: leftWidth)
        let top = baseline + 30
        return top + canvas.draw(detail, x: margin, y: top, color: PosterInk.secondary)
    }

    private func drawFigures(top: Float) {
        let cellWidth = leftWidth / 2
        let figures = Array(facts.figures.prefix(4))
        let labels = figures.map { $0.label.uppercased() }
        let labelSize = canvas.fittedSize(20, weight: .bold, strings: labels, kern: 2, width: cellWidth - 12)
        for (index, figure) in figures.enumerated() {
            let x = margin + Float(index % 2) * cellWidth
            let y = top + Float(index / 2) * 112
            let value = canvas.text(figure.value, size: 50, weight: .heavy, kern: -1, width: cellWidth)
            let valueHeight = canvas.draw(value, x: x, y: y, color: PosterInk.label)
            let label = canvas.text(labels[index], size: labelSize, weight: .bold, kern: 2, width: cellWidth)
            canvas.draw(label, x: x, y: y + valueHeight - 4, color: PosterInk.tertiary)
        }
    }

    private func drawTitles(left: Float, top: Float) {
        let width = self.width - margin - left
        let posterWidth: Float = 108
        let posterHeight: Float = 162
        for (index, title) in facts.titles.prefix(3).enumerated() {
            let y = top + Float(index) * 196
            let frame = Rect(x: left, y: y, width: posterWidth, height: posterHeight)
            canvas.drawPoster(content.posters[index], placeholder: Symbol(title.placeholderSymbol), rank: title.rank, in: frame, radius: 18,
                              badgeSize: 44, highlighted: index == 0)
            let textX = frame.maxX + 22
            let textWidth = width - posterWidth - 22
            let name = canvas.text(title.name, size: 30, weight: .bold, width: textWidth, lines: 3)
            let nameHeight = canvas.draw(name, x: textX, y: y + 20, color: PosterInk.label)
            let caption = canvas.text(title.caption, size: 24, weight: .medium, width: textWidth)
            canvas.draw(caption, x: textX, y: y + 20 + nameHeight + 6, color: PosterInk.secondary)
        }
    }

    private func drawGenres(left: Float, top: Float) {
        let height: Float = 48
        var x = left
        for genre in facts.genres.prefix(3) {
            let width = canvas.chipWidth(genre, height: height, fontSize: 24)
            guard x + width <= self.width - margin else { break }
            canvas.drawChip(genre, x: x, y: top, height: height, fontSize: 24)
            x += width + 12
        }
    }

    private func drawHeatmapBand() {
        guard let heatmap = facts.heatmap, heatmap.columns > 0 else { return }
        let height = contentWidth / Float(heatmap.columns) * 7
        canvas.drawHeatmap(heatmap, x: margin, y: canvas.size.height - 62 - 36 - height, width: contentWidth, height: height)
    }
}
