@preconcurrency import UIKit

/// Bakes an already-computed Year in Review into a share poster. Two formats share one palette and
/// drawing layer: a 9:16 story with the full telling, and a square that keeps the hero, the numbers
/// and the top titles for feeds. No new queries; everything comes from `WrappedShareContent`.
struct WrappedShareCardRenderer {
    enum Format: Int, CaseIterable {
        case story, square

        var title: String {
            switch self {
            case .story: return "Story"
            case .square: return "Square"
            }
        }

        var size: CGSize {
            switch self {
            case .story: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1080)
            }
        }
    }

    func render(_ content: WrappedShareContent, format: Format) -> UIImage {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let renderer = UIGraphicsImageRenderer(size: format.size, format: rendererFormat)
        return renderer.image { context in
            let canvas = WrappedShareCanvas(context: context.cgContext, size: format.size)
            switch format {
            case .story: StoryComposition(canvas: canvas, content: content).draw()
            case .square: SquareComposition(canvas: canvas, content: content).draw()
            }
        }
    }
}

private struct StoryComposition {
    let canvas: WrappedShareCanvas
    let content: WrappedShareContent

    private let margin: CGFloat = 84

    private var contentWidth: CGFloat { canvas.size.width - margin * 2 }

    func draw() {
        canvas.fillBackground()
        canvas.drawWash(from: content.leadPoster, height: 1180)
        canvas.drawGlow(center: CGPoint(x: canvas.size.width * 0.9, y: 300), radius: 760, alpha: 0.34)
        canvas.drawGlow(center: CGPoint(x: 0, y: canvas.size.height), radius: 800, alpha: 0.16)

        drawHeader()
        let detailTop = drawHero()
        let figuresBottom = drawFigures(top: detailTop + 56)
        let titlesBottom = drawTitles(top: figuresBottom + 64)
        let footerTop = canvas.size.height - 96
        drawFooter(top: footerTop)
        drawTail(titlesBottom: titlesBottom, footerTop: footerTop)
    }

    private func drawHeader() {
        canvas.drawWordmark(at: CGPoint(x: margin, y: 88), markSize: 56, textSize: 36)
        canvas.drawPeriodPill(content.period, trailingX: canvas.size.width - margin, top: 90, height: 52, fontSize: 26)
    }

    private func drawHero() -> CGFloat {
        let eyebrowFont = WrappedShareCanvas.rounded(34, .heavy)
        canvas.drawText(content.eyebrow.uppercased(), font: eyebrowFont, color: WrappedInk.accent, in: CGRect(x: margin, y: 218, width: contentWidth, height: eyebrowFont.lineHeight), kern: 5)
        let baseline = canvas.drawHeroFigure(content.heroValue, unit: content.heroUnit, origin: CGPoint(x: margin - 8, y: 262), maxWidth: contentWidth, fontSize: 320)
        let detailFont = WrappedShareCanvas.rounded(40, .semibold)
        let top = baseline + 40
        canvas.drawText(content.heroDetail, font: detailFont, color: WrappedInk.secondary, in: CGRect(x: margin, y: top, width: contentWidth, height: detailFont.lineHeight))
        return top + detailFont.lineHeight
    }

    private func drawFigures(top: CGFloat) -> CGFloat {
        let height: CGFloat = 132
        canvas.drawHairline(from: CGPoint(x: margin, y: top), to: CGPoint(x: canvas.size.width - margin, y: top))
        canvas.drawHairline(from: CGPoint(x: margin, y: top + height), to: CGPoint(x: canvas.size.width - margin, y: top + height))
        let count = CGFloat(max(content.figures.count, 1))
        let columnWidth = contentWidth / count
        let valueFont = WrappedShareCanvas.rounded(60, .heavy)
        let labelFont = WrappedShareCanvas.rounded(22, .bold)
        for (index, figure) in content.figures.enumerated() {
            let x = margin + columnWidth * CGFloat(index)
            canvas.drawText(figure.value, font: valueFont, color: WrappedInk.label, in: CGRect(x: x, y: top + 20, width: columnWidth, height: valueFont.lineHeight), alignment: .center, kern: -1)
            canvas.drawText(figure.label.uppercased(), font: labelFont, color: WrappedInk.tertiary, in: CGRect(x: x, y: top + 20 + valueFont.lineHeight - 2, width: columnWidth, height: labelFont.lineHeight), alignment: .center, kern: 2.5)
            if index > 0 {
                canvas.drawHairline(from: CGPoint(x: x, y: top + 28), to: CGPoint(x: x, y: top + height - 28))
            }
        }
        return top + height
    }

    private func drawTitles(top: CGFloat) -> CGFloat {
        guard !content.titles.isEmpty else { return top }
        canvas.drawSectionLabel("MOST WATCHED", at: CGPoint(x: margin, y: top), width: contentWidth, fontSize: 28)
        let gap: CGFloat = 28
        let columns: CGFloat = 3
        let posterWidth = floor((contentWidth - gap * (columns - 1)) / columns)
        let posterHeight = floor(posterWidth * 1.5)
        let posterTop = top + 58
        let nameFont = WrappedShareCanvas.rounded(32, .bold)
        let captionFont = WrappedShareCanvas.rounded(26, .medium)
        var bottom = posterTop
        for (index, title) in content.titles.prefix(3).enumerated() {
            let x = margin + CGFloat(index) * (posterWidth + gap)
            let rect = CGRect(x: x, y: posterTop, width: posterWidth, height: posterHeight)
            canvas.drawPoster(title, in: rect, radius: 26, badgeSize: 68, highlighted: index == 0)
            let nameHeight = canvas.drawText(title.name, font: nameFont, color: WrappedInk.label, in: CGRect(x: x, y: rect.maxY + 22, width: posterWidth, height: nameFont.lineHeight * 2), lines: 2)
            let captionY = rect.maxY + 22 + nameHeight + 6
            canvas.drawText(title.caption, font: captionFont, color: WrappedInk.secondary, in: CGRect(x: x, y: captionY, width: posterWidth, height: captionFont.lineHeight))
            bottom = max(bottom, captionY + captionFont.lineHeight)
        }
        return bottom
    }

    private func drawFooter(top: CGFloat) {
        let font = WrappedShareCanvas.rounded(26, .semibold)
        canvas.drawText("Watched on my own Plex server", font: font, color: WrappedInk.tertiary, in: CGRect(x: margin, y: top, width: contentWidth, height: font.lineHeight), alignment: .center, kern: 1)
    }

    /// Genres and the heatmap fill whatever room the titles leave, anchored above the footer.
    private func drawTail(titlesBottom: CGFloat, footerTop: CGFloat) {
        var cursor = footerTop - 40
        if let heatmap = content.heatmap, heatmap.columns > 0 {
            let stride = contentWidth / CGFloat(heatmap.columns)
            let height = stride * 7
            cursor -= height
            canvas.drawHeatmap(heatmap, in: CGRect(x: margin, y: cursor, width: contentWidth, height: height))
            cursor -= 40
        }
        guard !content.genres.isEmpty else { return }
        let chipHeight: CGFloat = 58
        let chipsTop = cursor - chipHeight
        guard chipsTop > titlesBottom + 24 else { return }
        drawGenres(top: chipsTop, height: chipHeight)
    }

    private func drawGenres(top: CGFloat, height: CGFloat) {
        var x = margin
        for genre in content.genres.prefix(4) {
            let font = WrappedShareCanvas.rounded(28, .semibold)
            let width = canvas.textWidth(genre, font: font) + height * 0.9
            guard x + width <= canvas.size.width - margin else { break }
            canvas.drawChip(genre, at: CGPoint(x: x, y: top), height: height, fontSize: 28)
            x += width + 16
        }
    }
}

private struct SquareComposition {
    let canvas: WrappedShareCanvas
    let content: WrappedShareContent

    private let margin: CGFloat = 64

    private var contentWidth: CGFloat { canvas.size.width - margin * 2 }

    func draw() {
        canvas.fillBackground()
        canvas.drawWash(from: content.leadPoster, height: 760)
        canvas.drawGlow(center: CGPoint(x: canvas.size.width * 0.92, y: 120), radius: 620, alpha: 0.32)
        canvas.drawGlow(center: CGPoint(x: 0, y: canvas.size.height), radius: 560, alpha: 0.14)

        canvas.drawWordmark(at: CGPoint(x: margin, y: 54), markSize: 44, textSize: 30)
        canvas.drawPeriodPill(content.period, trailingX: canvas.size.width - margin, top: 54, height: 44, fontSize: 22)

        let leftWidth: CGFloat = 470
        let detailBottom = drawHero(width: leftWidth)
        drawFigures(top: detailBottom + 40, width: leftWidth)
        let titlesLeft = margin + leftWidth + 56
        drawTitles(left: titlesLeft, top: 168)
        drawGenres(left: titlesLeft, top: 168 + 3 * 196 + 8)
        drawHeatmapBand()
        let footer = WrappedShareCanvas.rounded(22, .semibold)
        canvas.drawText("Watched on my own Plex server", font: footer, color: WrappedInk.tertiary, in: CGRect(x: margin, y: canvas.size.height - 62, width: contentWidth, height: footer.lineHeight), alignment: .center, kern: 1)
    }

    private func drawHero(width: CGFloat) -> CGFloat {
        let eyebrowFont = WrappedShareCanvas.rounded(26, .heavy)
        canvas.drawText(content.eyebrow.uppercased(), font: eyebrowFont, color: WrappedInk.accent, in: CGRect(x: margin, y: 160, width: width + 60, height: eyebrowFont.lineHeight), kern: 4)
        let baseline = canvas.drawHeroFigure(content.heroValue, unit: content.heroUnit, origin: CGPoint(x: margin - 6, y: 192), maxWidth: width, fontSize: 230)
        let detailFont = WrappedShareCanvas.rounded(30, .semibold)
        let top = baseline + 30
        canvas.drawText(content.heroDetail, font: detailFont, color: WrappedInk.secondary, in: CGRect(x: margin, y: top, width: width, height: detailFont.lineHeight))
        return top + detailFont.lineHeight
    }

    private func drawFigures(top: CGFloat, width: CGFloat) {
        let columns = 2
        let cellWidth = width / CGFloat(columns)
        let cellHeight: CGFloat = 112
        let valueFont = WrappedShareCanvas.rounded(50, .heavy)
        let labelFont = WrappedShareCanvas.rounded(20, .bold)
        for (index, figure) in content.figures.prefix(4).enumerated() {
            let x = margin + CGFloat(index % columns) * cellWidth
            let y = top + CGFloat(index / columns) * cellHeight
            canvas.drawText(figure.value, font: valueFont, color: WrappedInk.label, in: CGRect(x: x, y: y, width: cellWidth, height: valueFont.lineHeight), kern: -1)
            canvas.drawText(figure.label.uppercased(), font: labelFont, color: WrappedInk.tertiary, in: CGRect(x: x, y: y + valueFont.lineHeight - 4, width: cellWidth, height: labelFont.lineHeight), kern: 2)
        }
    }

    private func drawTitles(left: CGFloat, top: CGFloat) {
        let width = canvas.size.width - margin - left
        let posterWidth: CGFloat = 108
        let posterHeight: CGFloat = 162
        let rowHeight: CGFloat = 196
        let nameFont = WrappedShareCanvas.rounded(30, .bold)
        let captionFont = WrappedShareCanvas.rounded(24, .medium)
        for (index, title) in content.titles.prefix(3).enumerated() {
            let y = top + CGFloat(index) * rowHeight
            let rect = CGRect(x: left, y: y, width: posterWidth, height: posterHeight)
            canvas.drawPoster(title, in: rect, radius: 18, badgeSize: 44, highlighted: index == 0)
            let textX = rect.maxX + 22
            let textWidth = width - posterWidth - 22
            let nameHeight = canvas.drawText(title.name, font: nameFont, color: WrappedInk.label, in: CGRect(x: textX, y: y + 20, width: textWidth, height: nameFont.lineHeight * 3), lines: 3)
            canvas.drawText(title.caption, font: captionFont, color: WrappedInk.secondary, in: CGRect(x: textX, y: y + 20 + nameHeight + 6, width: textWidth, height: captionFont.lineHeight))
        }
    }

    private func drawGenres(left: CGFloat, top: CGFloat) {
        let height: CGFloat = 48
        let font = WrappedShareCanvas.rounded(24, .semibold)
        var x = left
        for genre in content.genres.prefix(3) {
            let width = canvas.textWidth(genre, font: font) + height * 0.9
            guard x + width <= canvas.size.width - margin else { break }
            canvas.drawChip(genre, at: CGPoint(x: x, y: top), height: height, fontSize: 24)
            x += width + 12
        }
    }

    private func drawHeatmapBand() {
        guard let heatmap = content.heatmap, heatmap.columns > 0 else { return }
        let stride = contentWidth / CGFloat(heatmap.columns)
        let height = stride * 7
        canvas.drawHeatmap(heatmap, in: CGRect(x: margin, y: canvas.size.height - 62 - 36 - height, width: contentWidth, height: height))
    }
}
