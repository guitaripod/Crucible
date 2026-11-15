import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The pulse of a title's Trakt community (`TVCommunityPulseView`), inside a focusable panel: Trakt's score with how its
/// voters spread, how many watch, play, list, discuss and love the title, and who is watching right now.
@MainActor
final class CommunityPulseContent: View {
    private let mark = BrandMarkView("trakt")
    private let histogram = RatingHistogramView()
    private var faces: [TraktAvatarView] = []
    private var snapshot: TraktCommunity.Snapshot?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [mark, histogram].forEach(addSubview)
    }

    override var isPointerInteractive: Bool { false }

    func apply(_ snapshot: TraktCommunity.Snapshot, animatesBars: Bool) {
        self.snapshot = snapshot
        mark.isHidden = snapshot.score == nil
        histogram.isHidden = snapshot.distribution == nil
        if let distribution = snapshot.distribution { histogram.show(distribution, animated: animatesBars) }
        let watching = Array(snapshot.watching.prefix(5))
        while faces.count < watching.count {
            let face = TraktAvatarView()
            faces.append(face)
            addSubview(face)
        }
        for (index, face) in faces.enumerated() {
            face.isHidden = index >= watching.count
            if index < watching.count { face.configure(watching[index]) }
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private var metrics: Metrics { Theme.current.metrics }
    private var scoreFont: Font { Font(size: metrics.tv(88), weight: .heavy) }
    private var numberFont: Font { Font(size: metrics.tv(40), weight: .bold) }
    private var markSide: Float { metrics.tv(44) }
    private var faceSide: Float { metrics.tv(48) }

    private var stats: [(symbol: Symbol, value: Int, label: String)] {
        guard let stats = snapshot?.stats else { return [] }
        var entries: [(Symbol, Int, String)] = [
            ("eye.fill", stats.watchers, TraktCommunityCopy.statWatchers),
            ("play.fill", stats.plays, TraktCommunityCopy.statPlays),
            ("list.bullet.rectangle.fill", stats.lists, TraktCommunityCopy.statLists),
            ("bubble.left.fill", stats.comments, TraktCommunityCopy.statComments),
        ]
        if let favorited = stats.favorited, favorited > 0 { entries.append(("heart.fill", favorited, TraktCommunityCopy.statFavorites)) }
        return entries
    }

    private var topHeight: Float {
        let score: Float = snapshot?.score == nil ? 0 : scoreFont.size * 1.25 + Theme.current.type.cardSubtitle.size * 1.4
        let bars: Float = snapshot?.distribution == nil ? 0 : histogram.sizeThatFits(Size(width: metrics.tv(600), height: 0)).height
        let live: Float = snapshot?.watching.isEmpty == false ? faceSide : 0
        return max(score, bars, live)
    }

    private var tilesHeight: Float {
        stats.isEmpty ? 0 : numberFont.size * 1.3 + Theme.current.type.cardSubtitle.size * 1.4
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let gap: Float = topHeight > 0 && tilesHeight > 0 ? metrics.tv(36) : 0
        return Size(width: size.width, height: topHeight + gap + tilesHeight)
    }

    /// Where the score block ends, so the histogram starts after it.
    private func scoreWidth(scale: Float) -> Float {
        guard let score = snapshot?.score else { return 0 }
        let value = TextLayout(TraktCopy.value(score), font: scoreFont, scale: scale)
        let votes = TextLayout(TraktCopy.detail(score), font: Theme.current.type.cardSubtitle, scale: scale)
        return max(markSide + metrics.tv(16) + value.size.width, votes.size.width)
    }

    override func layoutSubviews() {
        let scale = window?.scale ?? 1
        let top = topHeight
        mark.frame = Rect(x: 0, y: (top - markSide) / 2 - metrics.tv(14), width: markSide, height: markSide)
        let barsX = snapshot?.score == nil ? 0 : scoreWidth(scale: scale) + metrics.tv(64)
        let barsSize = histogram.sizeThatFits(Size(width: metrics.tv(600), height: 0))
        histogram.frame = Rect(x: barsX, y: (top - barsSize.height) / 2, width: min(barsSize.width, max(0, frame.width - barsX)), height: barsSize.height)
        var x = frame.width
        for face in faces.reversed() where !face.isHidden {
            x -= faceSide
            face.frame = Rect(x: x, y: (top - faceSide) / 2, width: faceSide, height: faceSide)
            x += metrics.tv(14)
        }
    }

    override func draw(_ context: inout DrawContext) {
        guard let snapshot, let scale = window?.scale else { return }
        let palette = Theme.current.palette
        let type = Theme.current.type
        let top = topHeight
        if let score = snapshot.score {
            let value = TextLayout(TraktCopy.value(score), font: scoreFont, scale: scale)
            let votes = TextLayout(TraktCopy.detail(score), font: type.cardSubtitle, scale: scale)
            let blockHeight = value.size.height + votes.size.height
            let y = ((top - blockHeight) / 2).rounded()
            context.text(value, at: Point(x: markSide + metrics.tv(16), y: y), color: palette.label)
            context.text(votes, at: Point(x: 0, y: y + value.size.height), color: palette.labelSecondary)
        }
        if !snapshot.watching.isEmpty {
            let label = TextLayout(TraktCommunityCopy.watchingNow(snapshot.watching.count), font: type.cardTitle, scale: scale)
            let firstFace = faces.first { !$0.isHidden }?.frame.minX ?? frame.width
            let labelX = firstFace - metrics.tv(14) - label.size.width
            context.text(label, at: Point(x: labelX, y: ((top - label.size.height) / 2).rounded()), color: palette.label)
            let dot = metrics.tv(16)
            context.fill(Rect(x: labelX - metrics.tv(14) - dot, y: (top - dot) / 2, width: dot, height: dot), radius: dot / 2,
                         color: Color(srgbRed: 1, green: 0.23, blue: 0.19))
        }
        guard !stats.isEmpty else { return }
        var x: Float = 0
        let y = top + (top > 0 ? metrics.tv(36) : 0)
        for entry in stats {
            let number = TextLayout(Formatters.compactCount(entry.value), font: numberFont, scale: scale)
            let caption = TextLayout(entry.label, font: type.cardSubtitle, scale: scale)
            let icon = metrics.tv(28)
            context.symbol(entry.symbol, in: Rect(x: x, y: y + (number.size.height - icon) / 2, width: icon, height: icon), color: palette.accent)
            context.text(number, at: Point(x: x + icon + metrics.tv(12), y: y), color: palette.label)
            context.text(caption, at: Point(x: x, y: y + number.size.height + metrics.tv(2)), color: palette.labelSecondary)
            x += max(icon + metrics.tv(12) + number.size.width, caption.size.width) + metrics.tv(48)
        }
    }
}

/// One Trakt comment as a card (`TVCommentCardView`), inside a focusable panel: who wrote it with their rating and how
/// long ago, the text with spoilers covered until revealed, and its likes, replies and reactions.
@MainActor
final class CommentCardContent: View {
    let commentID: Int
    private let avatar = TraktAvatarView()
    private let gif = GIFView()
    private var comment: TraktComment?
    private var isRevealed = false
    private var isLiked = false
    private var summary: TraktReactionSummary?
    private var mine: Set<TraktReaction> = []
    private var isMine = false

    init(commentID: Int) {
        self.commentID = commentID
        super.init()
        addSubview(avatar)
        addSubview(gif)
        gif.isHidden = true
    }

    override var isPointerInteractive: Bool { false }

    static var size: Size { Size(width: Theme.current.metrics.tv(640), height: Theme.current.metrics.tv(380)) }

    func apply(comment: TraktComment, isRevealed: Bool, isLiked: Bool, summary: TraktReactionSummary?, mine: Set<TraktReaction>, isMine: Bool) {
        self.comment = comment
        self.isRevealed = isRevealed
        self.isLiked = isLiked
        self.summary = summary
        self.mine = mine
        self.isMine = isMine
        avatar.configure(comment.user)
        let shownGIF = comment.isSpoiler && !isRevealed ? nil : comment.gifURL
        gif.isHidden = shownGIF == nil
        gif.url = shownGIF
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// The GIF takes what the card has left once two lines of text have room, at most 150 points on a TV.
    private var gifHeight: Float {
        guard !gif.isHidden else { return 0 }
        let type = Theme.current.type
        let top = insets.top + avatarSide + metrics.tv(18)
        let bottom = insets.bottom + type.cardSubtitle.size * 1.3 + metrics.tv(18)
        let twoLines = type.callout.size * 1.3 * 2
        return min(metrics.tv(150), max(0, frame.height - top - bottom - twoLines - metrics.tv(18)))
    }

    /// Whether the whole comment hides behind the spoiler cover.
    var isCovered: Bool { comment?.isSpoiler == true && !isRevealed }

    private var metrics: Metrics { Theme.current.metrics }
    private var insets: (top: Float, side: Float, bottom: Float) { (metrics.tv(28), metrics.tv(32), metrics.tv(24)) }
    private var avatarSide: Float { metrics.tv(64) }

    override func sizeThatFits(_ size: Size) -> Size { Self.size }

    override func layoutSubviews() {
        avatar.frame = Rect(x: insets.side, y: insets.top, width: avatarSide, height: avatarSide)
        let footerTop = frame.height - insets.bottom - Theme.current.type.cardSubtitle.size * 1.3
        gif.cornerRadius = metrics.radiusS
        gif.frame = Rect(x: insets.side, y: footerTop - metrics.tv(18) - gifHeight, width: frame.width - insets.side * 2, height: gifHeight)
    }

    /// VIP, Review and Spoiler, each in its colour.
    static func tags(_ comment: TraktComment) -> [(text: String, color: Color)] {
        let palette = Theme.current.palette
        var tags: [(String, Color)] = []
        if comment.user.isVIP { tags.append((TraktCommunityCopy.vip, palette.accent)) }
        if comment.isReview { tags.append((TraktCommunityCopy.review.uppercased(), Color(srgbRed: 0.35, green: 0.78, blue: 0.85))) }
        if comment.isSpoiler { tags.append((TraktCommunityCopy.spoiler.uppercased(), Color(srgbRed: 1, green: 0.27, blue: 0.23))) }
        return tags
    }

    override func draw(_ context: inout DrawContext) {
        guard let comment, let scale = window?.scale else { return }
        let palette = Theme.current.palette
        let type = Theme.current.type
        let textX = insets.side + avatarSide + metrics.tv(20)
        let textWidth = frame.width - textX - insets.side
        let nameText = isMine ? "\(comment.user.displayName) (\(TraktCommunityCopy.you))" : comment.user.displayName
        let name = TextLayout(nameText, font: type.cardTitle, maxWidth: textWidth, scale: scale)
        let metaText = [comment.authorRating.map { "★ \($0)/10" }, TraktCommunityCopy.age(comment.createdAt)].compactMap { $0 }.joined(separator: "  ·  ")
        let meta = TextLayout(metaText, font: type.cardSubtitle, maxWidth: textWidth, scale: scale)
        let headerHeight = name.size.height + metrics.tv(2) + meta.size.height
        let headerY = insets.top + ((avatarSide - headerHeight) / 2).rounded()
        context.text(name, at: Point(x: textX, y: headerY), color: palette.label)
        var tagX = textX + name.size.width + metrics.tv(12)
        for tag in Self.tags(comment) {
            let layout = TextLayout(tag.text, font: type.eyebrow, scale: scale)
            guard tagX + layout.size.width <= frame.width - insets.side else { break }
            context.text(layout, at: Point(x: tagX, y: headerY + (name.size.height - layout.size.height) / 2), color: tag.color)
            tagX += layout.size.width + metrics.tv(8)
        }
        context.text(meta, at: Point(x: textX, y: headerY + name.size.height + metrics.tv(2)), color: palette.labelSecondary)

        let footer = footerLayout(scale: scale)
        let footerY = frame.height - insets.bottom - footer.size.height
        let bodyTop = insets.top + avatarSide + metrics.tv(18)
        let gifRoom = gif.isHidden ? 0 : gifHeight + metrics.tv(18)
        let bodyArea = Rect(x: insets.side, y: bodyTop, width: frame.width - insets.side * 2, height: footerY - metrics.tv(18) - bodyTop - gifRoom)
        if isCovered {
            drawCover(in: bodyArea, scale: scale, context: &context)
        } else {
            let markup = Self.oneParagraph(CommentMarkup.markup(TraktCommentText(comment.text), revealed: isRevealed))
            let body = TextLayout(markup, font: type.callout, maxWidth: bodyArea.width, maxLines: max(1, Int(bodyArea.height / (type.callout.size * 1.3))),
                                  scale: scale, markup: true, inColor: true)
            context.clipped(to: bodyArea) { inner in inner.text(body, at: bodyArea.origin, color: palette.label) }
        }
        context.text(footer, at: Point(x: insets.side, y: footerY), color: palette.labelSecondary)
    }

    /// `markup` with its paragraphs run together, since Pango counts a line limit per paragraph and the card has room for
    /// a few lines in all.
    static func oneParagraph(_ markup: String) -> String {
        markup.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The cover over a comment that is a spoiler as a whole: an eye, "Spoiler" and how to reveal it.
    private func drawCover(in area: Rect, scale: Float, context: inout DrawContext) {
        let palette = Theme.current.palette
        let type = Theme.current.type
        context.fill(area, radius: metrics.radiusS, color: palette.surfaceRaised)
        let title = TextLayout(TraktCommunityCopy.spoilerCover, font: type.cardTitle, scale: scale)
        let hint = TextLayout(TraktCommunityCopy.pressToReveal, font: type.cardSubtitle, scale: scale)
        let icon = metrics.tv(40)
        let total = icon + metrics.tv(6) + title.size.height + metrics.tv(6) + hint.size.height
        var y = area.midY - total / 2
        context.symbol("eye.slash.fill", in: Rect(x: area.midX - icon / 2, y: y, width: icon, height: icon), color: palette.labelSecondary)
        y += icon + metrics.tv(6)
        context.text(title, at: Point(x: (area.midX - title.size.width / 2).rounded(), y: y), color: palette.label)
        y += title.size.height + metrics.tv(6)
        context.text(hint, at: Point(x: (area.midX - hint.size.width / 2).rounded(), y: y), color: palette.labelSecondary)
    }

    /// "♥ 12   💬 3   😂 5 ❤️ 2", the viewer's like and reactions marked.
    private func footerLayout(scale: Float) -> TextLayout {
        guard let comment else { return TextLayout("", font: Theme.current.type.cardSubtitle, scale: scale) }
        var parts = ["\(isLiked ? "♥" : "♡") \(Formatters.compactCount(comment.likeCount))", "💬 \(Formatters.compactCount(comment.replyCount))"]
        for (reaction, count) in (summary?.ranked ?? []).prefix(3) {
            parts.append("\(reaction.emoji) \(Formatters.compactCount(count))\(mine.contains(reaction) ? "•" : "")")
        }
        return TextLayout(parts.joined(separator: "     "), font: Theme.current.type.cardSubtitle, scale: scale, inColor: true)
    }
}

/// A card at the end of the comments rail (`TVCommunityActionCard`): Write a Review, or See All with how many there are.
@MainActor
final class CommunityActionContent: View {
    enum Kind: Equatable {
        case write
        case seeAll(Int)
    }

    var kind: Kind { didSet { if kind != oldValue { setNeedsDisplay() } } }

    init(_ kind: Kind) {
        self.kind = kind
        super.init()
    }

    override var isPointerInteractive: Bool { false }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: Theme.current.metrics.tv(420), height: CommentCardContent.size.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let metrics = Theme.current.metrics
        let palette = Theme.current.palette
        let symbol: Symbol
        let title: String
        let subtitle: String
        switch kind {
        case .write:
            (symbol, title, subtitle) = ("square.and.pencil", TraktCommunityCopy.writeReview, TraktCommunityCopy.emptyMessage)
        case .seeAll(let count):
            (symbol, title, subtitle) = ("bubble.left.and.bubble.right.fill", TraktCommunityCopy.seeAll, TraktCommunityCopy.commentCount(count))
        }
        let width = frame.width - metrics.tv(64)
        let titleLayout = TextLayout(title, font: Theme.current.type.title3, maxWidth: width, maxLines: 2, alignment: .center, scale: scale)
        let subtitleLayout = TextLayout(subtitle, font: Theme.current.type.cardSubtitle, maxWidth: width, maxLines: 2, alignment: .center, scale: scale)
        let icon = metrics.tv(64)
        let total = icon + metrics.tv(14) + titleLayout.size.height + metrics.tv(14) + subtitleLayout.size.height
        var y = ((frame.height - total) / 2).rounded()
        context.symbol(symbol, in: Rect(x: (frame.width - icon) / 2, y: y, width: icon, height: icon), color: palette.accent)
        y += icon + metrics.tv(14)
        context.text(titleLayout, at: Point(x: ((frame.width - titleLayout.size.width) / 2).rounded(), y: y), color: palette.label)
        y += titleLayout.size.height + metrics.tv(14)
        context.text(subtitleLayout, at: Point(x: ((frame.width - subtitleLayout.size.width) / 2).rounded(), y: y), color: palette.labelSecondary)
    }
}
