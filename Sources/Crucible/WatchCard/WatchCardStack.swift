import CrucibleCore
@preconcurrency import UIKit

/// One part of a card's text, in the order a card reads.
enum WatchCardBlock {
    enum Kind: CaseIterable {
        case eyebrow, title, context, credit, facts, genres, progress, rating, scores, take
    }

    case eyebrow(String)
    case title(String)
    case context(String)
    case credit(String)
    case facts(String)
    case genres([String])
    case progress(WatchCardFacts.Progress)
    case rating(UserRating, scores: [DetailRating])
    case scores([DetailRating])
    case take(String)

    var kind: Kind {
        switch self {
        case .eyebrow: return .eyebrow
        case .title: return .title
        case .context: return .context
        case .credit: return .credit
        case .facts: return .facts
        case .genres: return .genres
        case .progress: return .progress
        case .rating: return .rating
        case .scores: return .scores
        case .take: return .take
        }
    }
}

/// Sets a column of blocks: measures each at a width, spaces them, drops what does not fit, and draws them left-aligned
/// or centred.
@MainActor
struct WatchCardStack {
    struct Metrics {
        var eyebrow: CGFloat
        var title: CGFloat
        var titleMinimum: CGFloat
        var titleLines: Int
        var context: CGFloat
        var body: CGFloat
        var chip: CGFloat
        var score: CGFloat
        var star: CGFloat
        var take: CGFloat
        var takeLines: Int
        var progress: CGFloat
        var unit: CGFloat
    }

    let canvas: WatchCardCanvas
    let metrics: Metrics
    let alignment: NSTextAlignment

    private var palette: WatchCardPalette { canvas.palette }
    private var type: WatchCardType { canvas.type }

    // MARK: - Text styles

    private var eyebrowText: WatchCardText {
        WatchCardText(font: type.label(metrics.eyebrow), color: palette.accent, alignment: alignment, kern: metrics.eyebrow * 0.16)
    }

    private func titleText(_ size: CGFloat) -> WatchCardText {
        WatchCardText(
            font: type.title(size),
            color: palette.ink,
            alignment: alignment,
            kern: type.titleKern(size),
            lineHeight: size * (type.uppercasesTitle ? 1.0 : 1.1)
        )
    }

    private var contextText: WatchCardText {
        WatchCardText(font: type.body(metrics.context, .semibold), color: palette.inkSecondary, alignment: alignment)
    }

    private var creditText: WatchCardText {
        WatchCardText(font: type.body(metrics.body, .medium), color: palette.inkSecondary, alignment: alignment)
    }

    private var factsText: WatchCardText {
        WatchCardText(font: type.body(metrics.body, .medium), color: palette.inkTertiary, alignment: alignment)
    }

    private var takeText: WatchCardText {
        WatchCardText(font: type.quote(metrics.take), color: palette.ink, alignment: alignment, lineHeight: metrics.take * 1.32)
    }

    private var progressLabel: WatchCardText {
        WatchCardText(font: type.label(metrics.body * 0.78), color: palette.inkTertiary, alignment: alignment, kern: metrics.body * 0.1)
    }

    private var numberText: WatchCardText {
        WatchCardText(font: type.number(metrics.star * 0.86), color: palette.ink)
    }

    private func title(_ string: String) -> String {
        type.uppercasesTitle ? string.uppercased(with: Formatters.interfaceLocale) : string
    }

    /// The largest title size, down to the minimum, at which the title takes no more than its lines.
    private func titleSize(_ string: String, width: CGFloat) -> CGFloat {
        var size = metrics.title
        while size > metrics.titleMinimum, canvas.lines(title(string), titleText(size), width: width) > metrics.titleLines {
            size -= 2
        }
        return size
    }

    private func quoted(_ string: String) -> String {
        let locale = Formatters.interfaceLocale
        return "\(locale.quotationBeginDelimiter ?? "“")\(string)\(locale.quotationEndDelimiter ?? "”")"
    }

    // MARK: - Measuring

    func gap(before block: WatchCardBlock) -> CGFloat {
        let unit = metrics.unit
        switch block.kind {
        case .eyebrow: return 0
        case .title: return unit * 0.7
        case .context: return unit * 0.7
        case .credit: return unit * 1.4
        case .facts: return unit * 0.9
        case .genres: return unit * 2
        case .progress: return unit * 2.6
        case .rating: return unit * 2.6
        case .scores: return unit * 2
        case .take: return unit * 2.2
        }
    }

    func height(of block: WatchCardBlock, width: CGFloat) -> CGFloat {
        switch block {
        case .eyebrow(let text):
            return canvas.height(text.uppercased(with: Formatters.interfaceLocale), eyebrowText, width: width, lines: 1)
        case .title(let text):
            let size = titleSize(text, width: width)
            return canvas.height(title(text), titleText(size), width: width, lines: metrics.titleLines)
        case .context(let text):
            return canvas.height(text, contextText, width: width, lines: 2)
        case .credit(let text):
            return canvas.height(text, creditText, width: width, lines: 1)
        case .facts(let text):
            return canvas.height(text, factsText, width: width, lines: 2)
        case .genres:
            return metrics.chip
        case .progress:
            return progressLabel.line + metrics.unit * 0.8 + metrics.progress
        case .rating:
            return max(canvas.starHeight(size: metrics.star), numberText.line)
        case .scores:
            return metrics.score
        case .take(let text):
            return canvas.height(quoted(text), takeText, width: width, lines: metrics.takeLines)
        }
    }

    func height(of blocks: [WatchCardBlock], width: CGFloat) -> CGFloat {
        blocks.enumerated().reduce(0) { total, entry in
            total + (entry.offset == 0 ? 0 : gap(before: entry.element)) + height(of: entry.element, width: width)
        }
    }

    /// `blocks` cut to `width` (scores and genres keep only what fits their row, and go when nothing does), then without
    /// the kinds in `order`, one at a time from the first, until the rest fit in `limit`.
    func fitting(_ blocks: [WatchCardBlock], width: CGFloat, limit: CGFloat, dropping order: [WatchCardBlock.Kind]) -> [WatchCardBlock] {
        var kept = blocks.compactMap { narrowed($0, width: width) }
        for kind in order where height(of: kept, width: width) > limit {
            kept.removeAll { $0.kind == kind }
        }
        return kept
    }

    private func narrowed(_ block: WatchCardBlock, width: CGFloat) -> WatchCardBlock? {
        switch block {
        case .scores(let scores):
            let fitted = fitting(scores, width: width)
            return fitted.isEmpty ? nil : .scores(fitted)
        case .genres(let genres):
            let fitted = fittingGenres(genres, width: width)
            return fitted.isEmpty ? nil : .genres(fitted)
        case .rating(let rating, let scores):
            return .rating(rating, scores: fitting(scores, width: width - ratingWidth(rating) - metrics.star * 0.6))
        default:
            return block
        }
    }

    /// The scores from the first that fit side by side in `width`.
    private func fitting(_ scores: [DetailRating], width: CGFloat) -> [DetailRating] {
        var kept: [DetailRating] = []
        for score in scores where canvas.scoresWidth(kept + [score], height: metrics.score) <= width {
            kept.append(score)
        }
        return kept
    }

    /// The genres from the first that fit in one row of chips in `width`.
    private func fittingGenres(_ genres: [String], width: CGFloat) -> [String] {
        var kept: [String] = []
        var used: CGFloat = 0
        for genre in genres {
            let next = used + (kept.isEmpty ? 0 : metrics.chip * 0.24) + canvas.chipWidth(genre, height: metrics.chip)
            guard next <= width else { break }
            kept.append(genre)
            used = next
        }
        return kept
    }

    /// Whether the scores fit on the rating's own row at `width`, after the stars and the number.
    func scoresFitBesideRating(_ rating: UserRating, scores: [DetailRating], width: CGFloat) -> Bool {
        guard !scores.isEmpty, alignment != .center else { return false }
        return ratingWidth(rating) + metrics.star * 0.6 + canvas.scoresWidth(scores, height: metrics.score) <= width
    }

    private func ratingWidth(_ rating: UserRating) -> CGFloat {
        canvas.starsWidth(size: metrics.star) + metrics.star * 0.34 + canvas.width(rating.text, numberText)
    }

    // MARK: - Drawing

    @discardableResult
    func draw(_ blocks: [WatchCardBlock], at origin: CGPoint, width: CGFloat) -> CGFloat {
        var y = origin.y
        for (index, block) in blocks.enumerated() {
            if index > 0 { y += gap(before: block) }
            let height = height(of: block, width: width)
            draw(block, in: CGRect(x: origin.x, y: y, width: width, height: height))
            y += height
        }
        return y
    }

    private func draw(_ block: WatchCardBlock, in rect: CGRect) {
        switch block {
        case .eyebrow(let text):
            canvas.draw(text.uppercased(with: Formatters.interfaceLocale), eyebrowText, in: rect)
        case .title(let text):
            canvas.draw(title(text), titleText(titleSize(text, width: rect.width)), in: rect, lines: metrics.titleLines)
        case .context(let text):
            canvas.draw(text, contextText, in: rect, lines: 2)
        case .credit(let text):
            canvas.draw(text, creditText, in: rect)
        case .facts(let text):
            canvas.draw(text, factsText, in: rect, lines: 2)
        case .genres(let genres):
            drawGenres(genres, in: rect)
        case .progress(let progress):
            let label = progressLabel
            canvas.draw(progress.label.uppercased(with: Formatters.interfaceLocale), label, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: label.line))
            let barWidth = alignment == .center ? min(rect.width, metrics.progress * 46) : rect.width
            let barX = alignment == .center ? rect.midX - barWidth / 2 : rect.minX
            canvas.drawProgress(progress, in: CGRect(x: barX, y: rect.maxY - metrics.progress, width: barWidth, height: metrics.progress))
        case .rating(let rating, let scores):
            drawRating(rating, scores: scores, in: rect)
        case .scores(let scores):
            let width = canvas.scoresWidth(scores, height: metrics.score)
            let x = alignment == .center ? rect.midX - width / 2 : rect.minX
            canvas.drawScores(scores, at: CGPoint(x: x, y: rect.minY), height: metrics.score)
        case .take(let text):
            canvas.draw(quoted(text), takeText, in: rect, lines: metrics.takeLines)
        }
    }

    private func drawGenres(_ genres: [String], in rect: CGRect) {
        let gap = metrics.chip * 0.24
        var shown: [(String, CGFloat)] = []
        var used: CGFloat = 0
        for genre in genres {
            let width = canvas.chipWidth(genre, height: metrics.chip)
            let next = used + (shown.isEmpty ? 0 : gap) + width
            guard next <= rect.width else { break }
            shown.append((genre, width))
            used = next
        }
        var x = alignment == .center ? rect.midX - used / 2 : rect.minX
        for (genre, width) in shown {
            canvas.drawChip(genre, at: CGPoint(x: x, y: rect.minY), height: metrics.chip)
            x += width + gap
        }
    }

    /// The stars and the number beside them, with the scores on the far side of the row when they fit there.
    private func drawRating(_ rating: UserRating, scores: [DetailRating], in rect: CGRect) {
        let width = ratingWidth(rating)
        let x = alignment == .center ? rect.midX - width / 2 : rect.minX
        let starHeight = canvas.starHeight(size: metrics.star)
        let stars = canvas.drawStars(rating, at: CGPoint(x: x, y: rect.midY - starHeight / 2), size: metrics.star)
        let number = numberText
        canvas.draw(rating.text, number, in: CGRect(x: x + stars.width + metrics.star * 0.34, y: rect.midY - number.line / 2, width: canvas.width(rating.text, number) + 4, height: number.line))
        guard !scores.isEmpty else { return }
        let scoresWidth = canvas.scoresWidth(scores, height: metrics.score)
        canvas.drawScores(scores, at: CGPoint(x: rect.maxX - scoresWidth, y: rect.midY - metrics.score / 2), height: metrics.score)
    }
}
