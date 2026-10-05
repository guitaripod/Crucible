@preconcurrency import UIKit
import CoreImage.CIFilterBuiltins

/// The poster's palette: a warm near-black ground with the app's ember accent, fixed so the shared
/// image looks the same whatever appearance the phone is in.
enum WrappedInk {
    static let canvas = UIColor(hex: 0x0E0D0C)
    static let label = UIColor(hex: 0xF6F3EF)
    static let secondary = UIColor(hex: 0xF6F3EF).withAlphaComponent(0.70)
    static let tertiary = UIColor(hex: 0xF6F3EF).withAlphaComponent(0.46)
    static let accent = UIColor(hex: 0xFF9F0A)
    static let accentBright = UIColor(hex: 0xFFB340)
    static let hairline = UIColor.white.withAlphaComponent(0.14)
    static let well = UIColor.white.withAlphaComponent(0.07)
}

/// Thin drawing layer over a `CGContext` with the primitives the poster compositions share.
struct WrappedShareCanvas {
    let context: CGContext
    let size: CGSize

    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    func fillBackground() {
        WrappedInk.canvas.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }

    /// The lead poster, blurred and dimmed across the top of the card so the page takes its colour
    /// from the show that defined the period.
    func drawWash(from image: UIImage?, height: CGFloat) {
        guard let image, let blurred = image.blurred(radius: 22) else { return }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: height)
        context.saveGState()
        context.clip(to: rect)
        drawAspectFill(blurred, in: rect)
        WrappedInk.canvas.withAlphaComponent(0.42).setFill()
        context.fill(rect)
        context.restoreGState()
        fadeToCanvas(in: rect)
    }

    private func fadeToCanvas(in rect: CGRect) {
        let colors = [
            WrappedInk.canvas.withAlphaComponent(0).cgColor,
            WrappedInk.canvas.withAlphaComponent(0.85).cgColor,
            WrappedInk.canvas.cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.62, 1]) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        context.restoreGState()
    }

    func drawGlow(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let colors = [
            WrappedInk.accent.withAlphaComponent(alpha).cgColor,
            WrappedInk.accent.withAlphaComponent(0).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.saveGState()
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        context.restoreGState()
    }

    @discardableResult
    func drawText(
        _ string: String,
        font: UIFont,
        color: UIColor,
        in rect: CGRect,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0,
        lines: Int = 1
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern,
        ]
        let limit = min(rect.height, font.lineHeight * CGFloat(lines))
        let bounds = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: limit)
        let text = NSAttributedString(string: string, attributes: attributes)
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        let used = text.boundingRect(with: CGSize(width: rect.width, height: limit), options: .usesLineFragmentOrigin, context: nil)
        return ceil(min(used.height, limit))
    }

    func textWidth(_ string: String, font: UIFont, kern: CGFloat = 0) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: [.font: font, .kern: kern]).size().width)
    }

    func drawWordmark(at origin: CGPoint, markSize: CGFloat, textSize: CGFloat) {
        let configuration = UIImage.SymbolConfiguration(pointSize: markSize, weight: .heavy)
        if let flame = UIImage(systemName: "flame.fill", withConfiguration: configuration)?
            .withTintColor(WrappedInk.accent, renderingMode: .alwaysOriginal) {
            flame.draw(at: CGPoint(x: origin.x, y: origin.y))
        }
        let font = Self.rounded(textSize, .heavy)
        let x = origin.x + markSize + 14
        drawText("CRUCIBLE", font: font, color: WrappedInk.label, in: CGRect(x: x, y: origin.y + (markSize - font.lineHeight) / 2 + 2, width: 400, height: font.lineHeight), kern: 6)
    }

    func drawPeriodPill(_ text: String, trailingX: CGFloat, top: CGFloat, height: CGFloat, fontSize: CGFloat) {
        let font = Self.rounded(fontSize, .heavy)
        let width = textWidth(text, font: font, kern: 3) + height
        let rect = CGRect(x: trailingX - width, y: top, width: width, height: height)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: height / 2)
        WrappedInk.accent.withAlphaComponent(0.16).setFill()
        path.fill()
        WrappedInk.accent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
        drawText(text, font: font, color: WrappedInk.accentBright, in: CGRect(x: rect.minX, y: rect.minY + (height - font.lineHeight) / 2, width: width, height: font.lineHeight), alignment: .center, kern: 3)
    }

    /// A hero figure that shrinks to fit `maxWidth`, with its unit sitting on the same baseline.
    /// Returns the baseline y so the next element can be placed beneath it.
    @discardableResult
    func drawHeroFigure(_ value: String, unit: String, origin: CGPoint, maxWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        var point = fontSize
        var font = Self.rounded(point, .heavy)
        var unitFont = Self.rounded(point * 0.2, .bold)
        let gap = point * 0.12
        while textWidth(value, font: font, kern: -point * 0.02) + gap + textWidth(unit, font: unitFont) > maxWidth, point > 80 {
            point -= 6
            font = Self.rounded(point, .heavy)
            unitFont = Self.rounded(point * 0.2, .bold)
        }
        let kern = -point * 0.02
        let valueWidth = textWidth(value, font: font, kern: kern)
        drawText(value, font: font, color: WrappedInk.label, in: CGRect(x: origin.x, y: origin.y, width: valueWidth + 20, height: font.lineHeight), kern: kern)
        let baseline = origin.y + font.ascender
        let unitX = origin.x + valueWidth + point * 0.12
        drawText(unit, font: unitFont, color: WrappedInk.accentBright, in: CGRect(x: unitX, y: baseline - unitFont.ascender, width: maxWidth, height: unitFont.lineHeight))
        return baseline
    }

    func drawHairline(from start: CGPoint, to end: CGPoint) {
        context.saveGState()
        WrappedInk.hairline.setStroke()
        context.setLineWidth(2)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    func drawSectionLabel(_ text: String, at origin: CGPoint, width: CGFloat, fontSize: CGFloat) {
        let font = Self.rounded(fontSize, .heavy)
        let labelWidth = textWidth(text, font: font, kern: 5)
        drawText(text, font: font, color: WrappedInk.accent, in: CGRect(x: origin.x, y: origin.y, width: labelWidth + 10, height: font.lineHeight), kern: 5)
        let lineY = origin.y + font.lineHeight / 2
        drawHairline(from: CGPoint(x: origin.x + labelWidth + 28, y: lineY), to: CGPoint(x: origin.x + width, y: lineY))
    }

    @discardableResult
    func drawChip(_ text: String, at origin: CGPoint, height: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = Self.rounded(fontSize, .semibold)
        let width = textWidth(text, font: font) + height * 0.9
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        WrappedInk.well.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()
        drawText(text, font: font, color: WrappedInk.secondary, in: CGRect(x: rect.minX, y: rect.minY + (height - font.lineHeight) / 2, width: width, height: font.lineHeight), alignment: .center)
        return width
    }

    func drawPoster(_ title: WrappedShareContent.Title, in rect: CGRect, radius: CGFloat, badgeSize: CGFloat, highlighted: Bool) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: UIColor.black.withAlphaComponent(0.55).cgColor)
        WrappedInk.canvas.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        context.restoreGState()

        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        if let poster = title.poster {
            drawAspectFill(poster, in: rect)
        } else {
            WrappedInk.well.setFill()
            context.fill(rect)
            drawSymbol(title.placeholderSymbol, in: rect, pointSize: rect.width * 0.32)
        }
        context.restoreGState()

        let border = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: radius)
        border.lineWidth = highlighted ? 5 : 2
        (highlighted ? WrappedInk.accent : WrappedInk.hairline).setStroke()
        border.stroke()

        drawRankBadge(title.rank, at: CGPoint(x: rect.minX + badgeSize * 0.3, y: rect.minY + badgeSize * 0.3), size: badgeSize, highlighted: highlighted)
    }

    private func drawRankBadge(_ rank: Int, at origin: CGPoint, size: CGFloat, highlighted: Bool) {
        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let circle = UIBezierPath(ovalIn: rect)
        (highlighted ? WrappedInk.accent : UIColor.black.withAlphaComponent(0.62)).setFill()
        circle.fill()
        if !highlighted {
            UIColor.white.withAlphaComponent(0.28).setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
        let font = Self.rounded(size * 0.56, .heavy)
        let color = highlighted ? UIColor(hex: 0x1B1204) : UIColor.white
        drawText("\(rank)", font: font, color: color, in: CGRect(x: rect.minX, y: rect.minY + (size - font.lineHeight) / 2, width: size, height: font.lineHeight), alignment: .center)
    }

    func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat) {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(WrappedInk.tertiary, renderingMode: .alwaysOriginal) else { return }
        let target = CGPoint(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2)
        symbol.draw(at: target)
    }

    func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
    }

    func drawHeatmap(_ model: HeatmapModel, in rect: CGRect) {
        guard model.columns > 0 else { return }
        let stride = min(rect.width / CGFloat(model.columns), rect.height / 7)
        let edge = stride * 0.8
        let corner = edge * 0.24
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        var levels = [Int: Int]()
        for cell in model.cells { levels[cell.column * 7 + cell.row] = cell.level }
        let usedWidth = stride * CGFloat(model.columns)
        let originX = rect.minX + (rect.width - usedWidth) / 2
        for column in 0..<model.columns {
            for row in 0..<7 {
                let dayEpoch = model.firstDayEpoch + column * 7 + row
                if dayEpoch > model.lastDayEpoch { continue }
                let level = levels[column * 7 + row] ?? 0
                let cell = CGRect(x: originX + CGFloat(column) * stride, y: rect.minY + CGFloat(row) * stride, width: edge, height: edge)
                StatsStyle.heatColor(level: level).resolvedColor(with: dark).setFill()
                UIBezierPath(roundedRect: cell, cornerRadius: corner).fill()
            }
        }
    }
}

private extension UIImage {
    func blurred(radius: CGFloat) -> UIImage? {
        guard let input = CIImage(image: self) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
