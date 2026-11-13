import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// How one run of text on a card is set.
struct WatchCardText {
    let font: UIFont
    let color: UIColor
    var alignment: NSTextAlignment = .left
    var kern: CGFloat = 0
    var lineHeight: CGFloat?

    var line: CGFloat { lineHeight ?? font.lineHeight }

    func attributed(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern,
        ])
    }
}

/// The drawing primitives every card layout shares, in one look's palette and type.
@MainActor
struct WatchCardCanvas {
    let context: CGContext
    let size: CGSize
    let palette: WatchCardPalette
    let type: WatchCardType

    // MARK: - Ground

    func fillGround() {
        let colors = [palette.ground.cgColor, palette.groundDeep.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
            palette.ground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            return
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// The blurred artwork across the whole card, tinted with the ground so the type stays legible, and deepening toward
    /// the foot where the small print sits.
    func drawWash(_ image: UIImage?) {
        let rect = CGRect(origin: .zero, size: size)
        guard let image, palette.washAlpha > 0 else { return }
        context.saveGState()
        context.setAlpha(palette.washAlpha)
        drawAspectFill(image, in: rect)
        context.restoreGState()
        palette.ground.withAlphaComponent(0.30).setFill()
        context.fill(rect)
        let colors = [
            palette.groundDeep.withAlphaComponent(0.10).cgColor,
            palette.groundDeep.withAlphaComponent(0.55).cgColor,
            palette.groundDeep.withAlphaComponent(0.92).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    }

    func drawGlow(center: CGPoint, radius: CGFloat) {
        guard palette.glowAlpha > 0 else { return }
        let colors = [palette.accent.withAlphaComponent(palette.glowAlpha).cgColor, palette.accent.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// A printed page's thin rule inset from the edge, for the Paper look.
    func drawPageRule(inset: CGFloat) {
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset), cornerRadius: inset * 0.5)
        palette.hairline.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: - Text

    func lines(_ string: String, _ text: WatchCardText, width: CGFloat) -> Int {
        let bounds = text.attributed(string).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, context: nil)
        return max(1, Int((bounds.height / text.line).rounded()))
    }

    func height(_ string: String, _ text: WatchCardText, width: CGFloat, lines limit: Int) -> CGFloat {
        CGFloat(min(lines(string, text, width: width), limit)) * text.line
    }

    @discardableResult
    func draw(_ string: String, _ text: WatchCardText, in rect: CGRect, lines limit: Int = 1) -> CGFloat {
        let height = self.height(string, text, width: rect.width, lines: limit)
        text.attributed(string).draw(
            with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        return height
    }

    func width(_ string: String, _ text: WatchCardText) -> CGFloat {
        ceil(text.attributed(string).size().width)
    }

    // MARK: - Artwork

    func drawPoster(_ image: UIImage?, symbol: String, in rect: CGRect, radius: CGFloat) {
        let shape = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: rect.height * 0.035), blur: rect.height * 0.08, color: UIColor.black.withAlphaComponent(palette.posterShadow).cgColor)
        palette.groundDeep.setFill()
        shape.fill()
        context.restoreGState()

        context.saveGState()
        shape.addClip()
        if let image {
            drawAspectFill(image, in: rect)
        } else {
            palette.well.setFill()
            context.fill(rect)
            drawSymbol(symbol, centeredIn: rect, pointSize: rect.width * 0.3, color: palette.inkTertiary)
        }
        context.restoreGState()

        let border = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: radius)
        border.lineWidth = 2
        (palette.isDark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.10)).setStroke()
        border.stroke()
    }

    func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        context.restoreGState()
    }

    func drawSymbol(_ name: String, centeredIn rect: CGRect, pointSize: CGFloat, color: UIColor) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        symbol.draw(at: CGPoint(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2))
    }

    // MARK: - Rating

    private func star(_ size: CGFloat, _ color: UIColor) -> UIImage? {
        UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    func starsWidth(size: CGFloat) -> CGFloat {
        let star = star(size, palette.accent)?.size.width ?? size
        return star * CGFloat(UserRating.maxStars) + size * 0.16 * CGFloat(UserRating.maxStars - 1)
    }

    /// Five stars at `size`, the viewer's share of each in the accent over a faint whole star, so a half star reads as half.
    @discardableResult
    func drawStars(_ rating: UserRating, at origin: CGPoint, size: CGFloat) -> CGSize {
        guard let full = star(size, palette.accent), let empty = star(size, palette.well.withAlphaComponent(palette.isDark ? 0.22 : 0.12)) else { return .zero }
        let gap = size * 0.16
        for index in 0..<UserRating.maxStars {
            let x = origin.x + CGFloat(index) * (full.size.width + gap)
            let rect = CGRect(x: x, y: origin.y, width: full.size.width, height: full.size.height)
            empty.draw(in: rect)
            let share = min(1, max(0, rating.stars - Double(index)))
            guard share > 0 else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(share), height: rect.height))
            full.draw(in: rect)
            context.restoreGState()
        }
        return CGSize(width: starsWidth(size: size), height: full.size.height)
    }

    func starHeight(size: CGFloat) -> CGFloat {
        star(size, palette.accent)?.size.height ?? size
    }

    // MARK: - Chips, scores, progress

    func chipWidth(_ text: String, height: CGFloat) -> CGFloat {
        width(text, chipText(height)) + height * 0.9
    }

    private func chipText(_ height: CGFloat) -> WatchCardText {
        WatchCardText(font: type.body(height * 0.48, .semibold), color: palette.inkSecondary, alignment: .center)
    }

    func drawChip(_ text: String, at origin: CGPoint, height: CGFloat) {
        let rect = CGRect(x: origin.x, y: origin.y, width: chipWidth(text, height: height), height: height)
        palette.well.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()
        let style = chipText(height)
        draw(text, style, in: CGRect(x: rect.minX, y: rect.midY - style.line / 2, width: rect.width, height: style.line))
    }

    private func scoreText(_ height: CGFloat) -> WatchCardText {
        WatchCardText(font: type.body(height * 0.66, .bold), color: palette.ink)
    }

    private func mark(for rating: DetailRating, height: CGFloat) -> UIImage? {
        guard case .score(let score) = rating.mark else { return nil }
        let brand = BrandMark(score: score)
        guard let image = brand.image else { return nil }
        let resolved = image.imageAsset?.image(with: palette.traits) ?? image
        let markHeight = height * (brand.isWordmark ? 0.62 : 0.78)
        let width = markHeight * resolved.size.width / max(resolved.size.height, 1)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: markHeight)).image { _ in
            resolved.draw(in: CGRect(x: 0, y: 0, width: width, height: markHeight))
        }
    }

    func scoreWidth(_ rating: DetailRating, height: CGFloat) -> CGFloat {
        let markWidth = mark(for: rating, height: height).map { $0.size.width + height * 0.22 } ?? 0
        return markWidth + width(rating.text, scoreText(height))
    }

    func scoresWidth(_ ratings: [DetailRating], height: CGFloat) -> CGFloat {
        let widths = ratings.map { scoreWidth($0, height: height) }
        return widths.reduce(0, +) + CGFloat(max(0, ratings.count - 1)) * height * 0.7
    }

    /// Each score behind its source's own mark, in a row from `origin`.
    func drawScores(_ ratings: [DetailRating], at origin: CGPoint, height: CGFloat) {
        var x = origin.x
        let text = scoreText(height)
        for rating in ratings {
            if let mark = mark(for: rating, height: height) {
                mark.draw(at: CGPoint(x: x, y: origin.y + (height - mark.size.height) / 2))
                x += mark.size.width + height * 0.22
            }
            let valueWidth = width(rating.text, text)
            draw(rating.text, text, in: CGRect(x: x, y: origin.y + (height - text.line) / 2, width: valueWidth + 4, height: text.line))
            x += valueWidth + height * 0.7
        }
    }

    /// One segment per episode of a season (or season of a show), filled as far as it was watched; past a few dozen the
    /// segments would be slivers, so the whole run is one bar.
    func drawProgress(_ progress: WatchCardFacts.Progress, in rect: CGRect) {
        let count = progress.segments.count
        let gap = count > 1 ? min(rect.height * 0.9, rect.width / CGFloat(count) * 0.28) : 0
        let segmentWidth = count > 0 ? (rect.width - gap * CGFloat(count - 1)) / CGFloat(count) : 0
        guard count > 0, count <= 40, segmentWidth >= rect.height * 0.9 else {
            let share = progress.total > 0 ? Double(progress.watched) / Double(progress.total) : 0
            drawBar(share, in: rect)
            return
        }
        for (index, share) in progress.segments.enumerated() {
            drawBar(share, in: CGRect(x: rect.minX + CGFloat(index) * (segmentWidth + gap), y: rect.minY, width: segmentWidth, height: rect.height))
        }
    }

    private func drawBar(_ share: Double, in rect: CGRect) {
        let radius = rect.height / 2
        palette.well.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        guard share > 0 else { return }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * CGFloat(min(1, share))), height: rect.height)
        palette.accent.setFill()
        UIBezierPath(roundedRect: filled, cornerRadius: radius).fill()
    }

    // MARK: - Wordmark

    private func wordmarkText(_ height: CGFloat) -> WatchCardText {
        WatchCardText(font: type.label(height * 0.62), color: palette.ink, kern: height * 0.14)
    }

    private func flame(_ height: CGFloat) -> UIImage? {
        UIImage(systemName: "flame.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: height * 0.78, weight: .heavy))?
            .withTintColor(palette.accent, renderingMode: .alwaysOriginal)
    }

    func wordmarkWidth(height: CGFloat) -> CGFloat {
        (flame(height)?.size.width ?? 0) + height * 0.28 + width("CRUCIBLE", wordmarkText(height))
    }

    /// The flame and CRUCIBLE, `height` tall, from `origin`.
    func drawWordmark(at origin: CGPoint, height: CGFloat) {
        var x = origin.x
        if let flame = flame(height) {
            flame.draw(at: CGPoint(x: x, y: origin.y + (height - flame.size.height) / 2))
            x += flame.size.width + height * 0.28
        }
        let text = wordmarkText(height)
        draw("CRUCIBLE", text, in: CGRect(x: x, y: origin.y + (height - text.line) / 2 + height * 0.03, width: width("CRUCIBLE", text) + 8, height: text.line))
    }
}
