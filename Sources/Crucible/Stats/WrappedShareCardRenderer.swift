import UIKit

/// Bakes the already-computed aggregates (plus a heatmap thumbnail and top posters) into a portrait
/// share poster via UIGraphicsImageRenderer. No new queries.
struct WrappedShareCardRenderer {
    struct Input {
        let title: String
        let subtitle: String
        let overview: StatsOverview
        let heatmap: HeatmapModel?
        let posters: [UIImage]
    }

    private let size = CGSize(width: 1080, height: 1920)

    func render(_ input: Input) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            drawBackground(cg)

            drawText(input.title, font: .systemFont(ofSize: 84, weight: .heavy), color: .white, rect: CGRect(x: 80, y: 150, width: size.width - 160, height: 200), alignment: .left)
            drawText(input.subtitle.uppercased(), font: .systemFont(ofSize: 34, weight: .semibold), color: UIColor.white.withAlphaComponent(0.7), rect: CGRect(x: 84, y: 330, width: size.width - 160, height: 60), alignment: .left)

            var y: CGFloat = 470
            if let model = input.heatmap, model.columns > 0 {
                let targetWidth = size.width - 160
                let stride = targetWidth / CGFloat(model.columns)
                let h = stride * 7
                drawHeatmap(cg, model: model, rect: CGRect(x: 80, y: y, width: targetWidth, height: h), stride: stride)
                y += h + 70
            }

            let tiles: [(String, String)] = [
                (StatsStyle.abbreviatedCount(input.overview.totalPlays), "Plays"),
                ("\(input.overview.daysActive)", "Days Active"),
                (StatsStyle.abbreviatedCount(input.overview.showsWatched), "Shows"),
                (StatsStyle.abbreviatedCount(input.overview.moviesWatched), "Movies"),
                ("\(input.overview.longestStreak)", "Day Streak"),
                (input.overview.estHours.map { StatsStyle.hoursLabel($0) + "h" } ?? "—", "Watched"),
            ]
            drawTileGrid(cg, tiles: tiles, top: y)
            y += 2 * 220 + 40

            drawPosters(input.posters, top: min(y, size.height - 440))

            drawText("CRUCIBLE", font: .systemFont(ofSize: 40, weight: .heavy), color: StatsStyle.accent, rect: CGRect(x: 0, y: size.height - 110, width: size.width, height: 60), alignment: .center)
        }
    }

    private func drawHeatmap(_ cg: CGContext, model: HeatmapModel, rect: CGRect, stride: CGFloat) {
        let edge = stride * 0.82
        let corner = edge * 0.22
        let darkTrait = UITraitCollection(userInterfaceStyle: .dark)
        var levels = [Int: Int]()
        for cell in model.cells { levels[cell.column * 7 + cell.row] = cell.level }
        for column in 0..<model.columns {
            for row in 0..<7 {
                let dayEpoch = model.firstDayEpoch + column * 7 + row
                if dayEpoch > model.lastDayEpoch { continue }
                let level = levels[column * 7 + row] ?? 0
                let x = rect.minX + CGFloat(column) * stride
                let cellY = rect.minY + CGFloat(row) * stride
                let cellRect = CGRect(x: x, y: cellY, width: edge, height: edge)
                StatsStyle.heatColor(level: level).resolvedColor(with: darkTrait).setFill()
                UIBezierPath(roundedRect: cellRect, cornerRadius: corner).fill()
            }
        }
    }

    private func drawBackground(_ cg: CGContext) {
        let colors = [
            UIColor(red: 0.18, green: 0.09, blue: 0.02, alpha: 1).cgColor,
            UIColor.black.cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        StatsStyle.accent.withAlphaComponent(0.9).setFill()
        cg.fill(CGRect(x: 80, y: 130, width: 90, height: 10))
    }

    private func drawTileGrid(_ cg: CGContext, tiles: [(String, String)], top: CGFloat) {
        let columns = 3
        let gap: CGFloat = 30
        let tileWidth = (size.width - 160 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let tileHeight: CGFloat = 190
        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let col = index % columns
            let x = 80 + CGFloat(col) * (tileWidth + gap)
            let y = top + CGFloat(row) * (tileHeight + gap)
            let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: tileWidth, height: tileHeight), cornerRadius: 28)
            UIColor.white.withAlphaComponent(0.06).setFill()
            path.fill()
            drawText(tile.0, font: .systemFont(ofSize: 62, weight: .heavy), color: .white, rect: CGRect(x: x, y: y + 44, width: tileWidth, height: 70), alignment: .center)
            drawText(tile.1.uppercased(), font: .systemFont(ofSize: 24, weight: .semibold), color: UIColor.white.withAlphaComponent(0.6), rect: CGRect(x: x, y: y + 120, width: tileWidth, height: 34), alignment: .center)
        }
    }

    private func drawPosters(_ posters: [UIImage], top: CGFloat) {
        let shown = Array(posters.prefix(3))
        guard !shown.isEmpty else { return }
        let gap: CGFloat = 30
        let count = CGFloat(shown.count)
        let width = (size.width - 160 - gap * (count - 1)) / count
        let height = width * 1.5
        for (index, poster) in shown.enumerated() {
            let x = 80 + CGFloat(index) * (width + gap)
            let rect = CGRect(x: x, y: top, width: width, height: height)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 20)
            path.addClip()
            poster.draw(in: rect)
            UIGraphicsGetCurrentContext()?.resetClip()
        }
    }

    private func drawText(_ string: String, font: UIFont, color: UIColor, rect: CGRect, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        string.draw(in: rect, withAttributes: attributes)
    }
}
