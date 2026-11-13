import CrucibleCore
@preconcurrency import UIKit

/// Everything one card image is drawn from: the title's facts, the viewer's rating and words, their choices and the
/// prepared artwork.
struct WatchCardDraft {
    var facts: WatchCardFacts
    var rating: UserRating?
    var take: String?
    var options: WatchCardOptions
    var artwork: WatchCardArtwork

    var cleanTake: String? { WatchCardTake.clean(take) }

    /// The blocks beside or under the artwork: what the title is and the facts the viewer chose to show.
    var infoBlocks: [WatchCardBlock] {
        var blocks: [WatchCardBlock] = [.eyebrow(facts.eyebrow), .title(facts.title)]
        if let context = facts.context { blocks.append(.context(context)) }
        guard options.showsDetails else { return blocks }
        if let credit = facts.credit { blocks.append(.credit(credit)) }
        if !facts.facts.isEmpty { blocks.append(.facts(Self.unbroken(facts.facts))) }
        if !facts.genres.isEmpty { blocks.append(.genres(facts.genres)) }
        return blocks
    }

    /// The facts on one line where they fit, wrapping only after a separator so "4 Seasons" and "TV-MA" never split and
    /// no line starts with a dot.
    private static func unbroken(_ facts: [String]) -> String {
        facts.map { fact in
            fact.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "\u{2060}-\u{2060}")
        }.joined(separator: "\u{00A0}\u{00A0}·\u{00A0} ")
    }

    var shownScores: [DetailRating] { options.showsScores ? facts.scores : [] }

    var shownRating: UserRating? { options.showsRating ? rating : nil }

    var progress: WatchCardFacts.Progress? { options.showsWatched ? facts.progress : nil }

    var watchedLine: String? {
        guard options.showsWatched, !facts.watched.isEmpty else { return nil }
        return facts.watched.joined(separator: "  ·  ").uppercased(with: Formatters.interfaceLocale)
    }

    /// The verdict: the stars (with the scores on their row when `merging`), the scores alone otherwise, and the
    /// viewer's words.
    func verdictBlocks(mergingScores merging: Bool) -> [WatchCardBlock] {
        var blocks: [WatchCardBlock] = []
        if let progress { blocks.append(.progress(progress)) }
        let scores = shownScores
        if let rating = shownRating {
            blocks.append(.rating(rating, scores: merging ? scores : []))
            if !merging, !scores.isEmpty { blocks.append(.scores(scores)) }
        } else if !scores.isEmpty {
            blocks.append(.scores(scores))
        }
        if let take = cleanTake { blocks.append(.take(take)) }
        return blocks
    }
}

/// Draws a watch card in its format and look. The same draft always draws the same image, so a preview is exactly what
/// is shared.
@MainActor
enum WatchCardRenderer {
    static func render(_ draft: WatchCardDraft) -> UIImage {
        let pixels = draft.options.format.pixelSize
        let size = CGSize(width: pixels.width, height: pixels.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let canvas = WatchCardCanvas(
                context: context.cgContext,
                size: size,
                palette: WatchCardPalette.make(draft.options.style, tone: draft.artwork.tone),
                type: WatchCardType(style: draft.options.style)
            )
            drawGround(canvas, draft: draft)
            switch draft.options.format {
            case .card: CardLayout(canvas: canvas, draft: draft).draw()
            case .story: StoryLayout(canvas: canvas, draft: draft).draw()
            case .square: SquareLayout(canvas: canvas, draft: draft).draw()
            }
        }
    }

    private static func drawGround(_ canvas: WatchCardCanvas, draft: WatchCardDraft) {
        canvas.fillGround()
        let wash = draft.options.style == .noir ? draft.artwork.monochromeWash : draft.artwork.wash
        canvas.drawWash(wash)
        canvas.drawGlow(center: CGPoint(x: canvas.size.width * 0.92, y: canvas.size.height * 0.04), radius: canvas.size.width * 0.75)
        if draft.options.style == .paper {
            canvas.drawPageRule(inset: 30)
        }
    }

    /// The small print along the foot: when it was watched on the left, the wordmark on the right.
    static func drawFoot(_ canvas: WatchCardCanvas, line: String?, minX: CGFloat, maxX: CGFloat, centerY: CGFloat, height: CGFloat) {
        let markWidth = canvas.wordmarkWidth(height: height)
        canvas.drawWordmark(at: CGPoint(x: maxX - markWidth, y: centerY - height / 2), height: height)
        guard let line else { return }
        let text = footText(canvas, size: height * 0.56)
        canvas.draw(line, text, in: CGRect(x: minX, y: centerY - text.line / 2, width: maxX - minX - markWidth - height, height: text.line))
    }

    static func footText(_ canvas: WatchCardCanvas, size: CGFloat, alignment: NSTextAlignment = .left) -> WatchCardText {
        WatchCardText(font: canvas.type.label(size), color: canvas.palette.inkTertiary, alignment: alignment, kern: size * 0.12)
    }
}

/// 4:5, for feeds: the poster with the title beside it, as tall as the verdict across the card beneath leaves room for,
/// and the foot at the bottom.
@MainActor
private struct CardLayout {
    let canvas: WatchCardCanvas
    let draft: WatchCardDraft

    private let margin: CGFloat = 64
    private let footHeight: CGFloat = 44
    private let verdictGap: CGFloat = 54
    private let posterHeights: ClosedRange<CGFloat> = 540...740

    private var stack: WatchCardStack {
        WatchCardStack(canvas: canvas, metrics: .init(
            eyebrow: 27, title: 76, titleMinimum: 42, titleLines: 4, context: 36, body: 30, chip: 52,
            score: 48, star: 76, take: 42, takeLines: 3, progress: 17, unit: 13
        ), alignment: .left)
    }

    func draw() {
        let stack = stack
        let width = canvas.size.width - margin * 2
        let footY = canvas.size.height - margin - footHeight / 2
        let available = footY - footHeight / 2 - 44 - margin

        let merging = draft.shownRating.map { stack.scoresFitBesideRating($0, scores: draft.shownScores, width: width) } ?? false
        let verdict = stack.fitting(
            draft.verdictBlocks(mergingScores: merging),
            width: width,
            limit: available - posterHeights.lowerBound - verdictGap,
            dropping: [.scores, .progress, .take]
        )
        let verdictHeight = verdict.isEmpty ? 0 : verdictGap + stack.height(of: verdict, width: width)
        let posterHeight = min(posterHeights.upperBound, max(posterHeights.lowerBound, available - verdictHeight))
        let posterWidth = (posterHeight / 1.5).rounded()
        let columnX = margin + posterWidth + 48
        let columnWidth = canvas.size.width - margin - columnX

        let column = stack.fitting(draft.infoBlocks, width: columnWidth, limit: posterHeight + 24, dropping: [.genres, .credit, .facts, .context])
        let columnHeight = stack.height(of: column, width: columnWidth)
        let topHeight = max(posterHeight, columnHeight)

        let top = margin + max(0, (available - topHeight - verdictHeight) * 0.45)
        canvas.drawPoster(draft.artwork.poster, symbol: draft.facts.placeholderSymbol, in: CGRect(x: margin, y: top + (topHeight - posterHeight) / 2, width: posterWidth, height: posterHeight), radius: 28)
        stack.draw(column, at: CGPoint(x: columnX, y: top + (topHeight - columnHeight) / 2), width: columnWidth)
        if !verdict.isEmpty {
            stack.draw(verdict, at: CGPoint(x: margin, y: top + topHeight + verdictGap), width: width)
        }
        WatchCardRenderer.drawFoot(canvas, line: draft.watchedLine, minX: margin, maxX: canvas.size.width - margin, centerY: footY, height: footHeight)
    }
}

/// 9:16, for stories: everything centred, the poster as large as the words under it allow, the foot clear of the reply
/// bar a story app lays over the bottom.
@MainActor
private struct StoryLayout {
    let canvas: WatchCardCanvas
    let draft: WatchCardDraft

    private let margin: CGFloat = 96
    private let markHeight: CGFloat = 46

    private var stack: WatchCardStack {
        WatchCardStack(canvas: canvas, metrics: .init(
            eyebrow: 31, title: 92, titleMinimum: 52, titleLines: 3, context: 42, body: 33, chip: 58,
            score: 52, star: 90, take: 48, takeLines: 4, progress: 18, unit: 14
        ), alignment: .center)
    }

    func draw() {
        let stack = stack
        let width = canvas.size.width - margin * 2
        let markY = canvas.size.height - 150
        let footText = WatchCardRenderer.footText(canvas, size: 26, alignment: .center)
        let footY = markY - 26 - footText.line
        let top: CGFloat = 170
        let bottom = (draft.watchedLine == nil ? markY : footY) - 60
        let available = bottom - top
        let posterGap: CGFloat = 60

        let blocks = stack.fitting(
            draft.infoBlocks + draft.verdictBlocks(mergingScores: false),
            width: width,
            limit: available - posterGap - 460,
            dropping: [.genres, .credit, .scores, .facts, .progress, .context]
        )
        let blocksHeight = stack.height(of: blocks, width: width)
        let posterHeight = min(880, max(420, available - posterGap - blocksHeight))
        let posterWidth = min(width, posterHeight / 1.5)
        let total = posterHeight + posterGap + blocksHeight
        let y = top + max(0, (available - total) / 2)

        canvas.drawPoster(draft.artwork.poster, symbol: draft.facts.placeholderSymbol, in: CGRect(x: (canvas.size.width - posterWidth) / 2, y: y, width: posterWidth, height: posterHeight), radius: 34)
        stack.draw(blocks, at: CGPoint(x: margin, y: y + posterHeight + posterGap), width: width)

        if let line = draft.watchedLine {
            canvas.draw(line, footText, in: CGRect(x: margin, y: footY, width: width, height: footText.line))
        }
        let markWidth = canvas.wordmarkWidth(height: markHeight)
        canvas.drawWordmark(at: CGPoint(x: (canvas.size.width - markWidth) / 2, y: markY), height: markHeight)
    }
}

/// 1:1: the poster beside a column that carries the title and the verdict together, the foot under both.
@MainActor
private struct SquareLayout {
    let canvas: WatchCardCanvas
    let draft: WatchCardDraft

    private let margin: CGFloat = 60
    private let footHeight: CGFloat = 40
    private let posterHeight: CGFloat = 600

    private var stack: WatchCardStack {
        WatchCardStack(canvas: canvas, metrics: .init(
            eyebrow: 24, title: 64, titleMinimum: 38, titleLines: 3, context: 32, body: 27, chip: 46,
            score: 42, star: 58, take: 34, takeLines: 3, progress: 14, unit: 11
        ), alignment: .left)
    }

    func draw() {
        let stack = stack
        let footY = canvas.size.height - margin - footHeight / 2
        let available = footY - footHeight / 2 - 40 - margin
        let posterHeight = min(self.posterHeight, available)
        let posterWidth = (posterHeight / 1.5).rounded()
        let columnX = margin + posterWidth + 44
        let columnWidth = canvas.size.width - margin - columnX

        let merging = draft.shownRating.map { stack.scoresFitBesideRating($0, scores: draft.shownScores, width: columnWidth) } ?? false
        let column = stack.fitting(
            draft.infoBlocks + draft.verdictBlocks(mergingScores: merging),
            width: columnWidth,
            limit: available,
            dropping: [.genres, .credit, .scores, .progress, .facts, .context, .take]
        )
        let columnHeight = stack.height(of: column, width: columnWidth)
        let groupHeight = max(posterHeight, columnHeight)
        let top = margin + max(0, (available - groupHeight) / 2)

        canvas.drawPoster(draft.artwork.poster, symbol: draft.facts.placeholderSymbol, in: CGRect(x: margin, y: top + (groupHeight - posterHeight) / 2, width: posterWidth, height: posterHeight), radius: 24)
        stack.draw(column, at: CGPoint(x: columnX, y: top + (groupHeight - columnHeight) / 2), width: columnWidth)
        WatchCardRenderer.drawFoot(canvas, line: draft.watchedLine, minX: margin, maxX: canvas.size.width - margin, centerY: footY, height: footHeight)
    }
}
