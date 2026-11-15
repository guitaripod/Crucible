import CrucibleCore
import CrucibleDesign
import UIKit

/// The pulse of a title's Trakt community on Apple TV: Trakt's score with how its voters spread, how many watch, play, list
/// and love the title, and who is watching right now. It takes focus so the shelf scrolls into view; Select lists who is
/// watching.
final class TVCommunityPulseView: TVFocusableSurface {
    private var content: UIView?
    private var shown: TraktCommunity.Snapshot?

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        accessibilityIdentifier = "trakt.community.pulse"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `snapshot`, redrawing what is inside the panel and never the panel itself, so a focused panel keeps the focus.
    func apply(_ snapshot: TraktCommunity.Snapshot, animatesBars: Bool) {
        guard snapshot != shown else { return }
        shown = snapshot
        content?.removeFromSuperview()
        let mark = UIImageView(image: BrandMark.trakt.image)
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 44), mark.heightAnchor.constraint(equalToConstant: 44)])
        let score = UILabel()
        score.font = UIFont.systemFont(ofSize: 88, weight: .heavy).withSystemDesign(.rounded)
        score.textColor = Theme.Color.label
        let votes = UILabel()
        votes.font = TVFont.cardSubtitle
        votes.textColor = Theme.Color.labelSecondary
        let markRow = UIStackView(arrangedSubviews: [mark, score])
        markRow.spacing = 16
        markRow.alignment = .center
        let scoreBlock = UIStackView(arrangedSubviews: [markRow, votes])
        scoreBlock.axis = .vertical
        scoreBlock.spacing = 4
        scoreBlock.alignment = .leading
        scoreBlock.isHidden = snapshot.score == nil
        if let value = snapshot.score {
            score.text = TraktCopy.value(value)
            votes.text = TraktCopy.detail(value)
        }

        let histogram = TraktHistogramView(maxHeight: 130)
        histogram.isHidden = snapshot.distribution == nil
        histogram.widthAnchor.constraint(equalToConstant: 600).isActive = true

        let tiles = UIStackView()
        tiles.axis = .horizontal
        tiles.spacing = 48
        if let stats = snapshot.stats {
            var entries: [(String, Int, String)] = [
                ("eye.fill", stats.watchers, TraktCommunityCopy.statWatchers),
                ("play.fill", stats.plays, TraktCommunityCopy.statPlays),
                ("list.bullet.rectangle.fill", stats.lists, TraktCommunityCopy.statLists),
                ("bubble.left.fill", stats.comments, TraktCommunityCopy.statComments),
            ]
            if let favorited = stats.favorited, favorited > 0 { entries.append(("heart.fill", favorited, TraktCommunityCopy.statFavorites)) }
            for entry in entries { tiles.addArrangedSubview(Self.tile(symbol: entry.0, value: entry.1, label: entry.2)) }
        }
        tiles.isHidden = snapshot.stats == nil

        let live = UIStackView()
        live.spacing = 14
        live.alignment = .center
        live.isHidden = snapshot.watching.isEmpty
        if !snapshot.watching.isEmpty {
            let dot = UIView()
            dot.backgroundColor = .systemRed
            dot.layer.cornerRadius = 8
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 16), dot.heightAnchor.constraint(equalToConstant: 16)])
            let faces = UIStackView()
            faces.spacing = -14
            for user in snapshot.watching.prefix(5) {
                let avatar = TraktAvatarView(diameter: 48)
                avatar.configure(user)
                avatar.layer.borderWidth = 3
                avatar.layer.borderColor = Theme.Color.surface.cgColor
                faces.addArrangedSubview(avatar)
            }
            let label = UILabel()
            label.text = TraktCommunityCopy.watchingNow(snapshot.watching.count)
            label.font = TVFont.cardTitle
            label.textColor = Theme.Color.label
            live.addArrangedSubview(dot)
            live.addArrangedSubview(label)
            live.addArrangedSubview(faces)
        }

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [scoreBlock, histogram, spacer, live])
        top.spacing = 64
        top.alignment = .center
        let stack = UIStackView(arrangedSubviews: [top, tiles])
        stack.axis = .vertical
        stack.spacing = 36
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        content = stack
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        layoutIfNeeded()
        if let distribution = snapshot.distribution { histogram.show(distribution, animated: animatesBars) }
        accessibilityLabel = [
            snapshot.score.map(TraktCopy.accessibilityLabel),
            snapshot.stats.map { "\(TraktCommunityCopy.statWatchers) \(Formatters.compactCount($0.watchers)), \(TraktCommunityCopy.statPlays) \(Formatters.compactCount($0.plays))" },
            snapshot.watching.isEmpty ? nil : TraktCommunityCopy.watchingNow(snapshot.watching.count),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private static func tile(symbol: String, value: Int, label: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        let number = UILabel()
        number.text = Formatters.compactCount(value)
        number.font = UIFont.systemFont(ofSize: 40, weight: .bold).withSystemDesign(.rounded)
        number.textColor = Theme.Color.label
        let caption = UILabel()
        caption.text = label
        caption.font = TVFont.cardSubtitle
        caption.textColor = Theme.Color.labelSecondary
        let numberRow = UIStackView(arrangedSubviews: [icon, number])
        numberRow.spacing = 12
        numberRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [numberRow, caption])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }
}

/// One Trakt comment as a card on Apple TV: who wrote it with their rating, the text with spoilers covered, and its likes,
/// replies and reactions. Select reads it in full; a long press likes, reacts or reports.
final class TVCommentCardView: TVFocusableSurface {
    static let size = CGSize(width: 640, height: 380)

    let commentID: Int
    private let avatar = TraktAvatarView(diameter: 64)
    private let name = UILabel()
    private let tags = UIStackView()
    private let meta = UILabel()
    private let body = UILabel()
    private let cover = UIView()
    private let footer = UILabel()
    private let gif = TraktGIFView(cornerRadius: Theme.Radius.s)

    init(commentID: Int) {
        self.commentID = commentID
        super.init(cornerRadius: Theme.Radius.l)
        name.font = TVFont.cardTitle
        name.textColor = Theme.Color.label
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tags.spacing = 8
        tags.setContentHuggingPriority(.required, for: .horizontal)
        let nameEnd = UIView()
        nameEnd.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [name, tags, nameEnd])
        nameRow.spacing = 12
        nameRow.alignment = .center
        meta.font = TVFont.cardSubtitle
        meta.textColor = Theme.Color.labelSecondary
        let names = UIStackView(arrangedSubviews: [nameRow, meta])
        names.axis = .vertical
        names.spacing = 2
        let header = UIStackView(arrangedSubviews: [avatar, names])
        header.spacing = 20
        header.alignment = .center

        body.numberOfLines = 5
        body.lineBreakMode = .byTruncatingTail
        cover.backgroundColor = Theme.Color.surfaceRaised
        cover.layer.cornerRadius = Theme.Radius.s
        let coverIcon = UIImageView(image: UIImage(systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)))
        coverIcon.tintColor = Theme.Color.labelSecondary
        let coverTitle = UILabel()
        coverTitle.text = TraktCommunityCopy.spoilerCover
        coverTitle.font = TVFont.cardTitle
        coverTitle.textColor = Theme.Color.label
        let coverHint = UILabel()
        coverHint.text = TraktCommunityCopy.pressToReveal
        coverHint.font = TVFont.cardSubtitle
        coverHint.textColor = Theme.Color.labelSecondary
        let coverStack = UIStackView(arrangedSubviews: [coverIcon, coverTitle, coverHint])
        coverStack.axis = .vertical
        coverStack.alignment = .center
        coverStack.spacing = 6
        coverStack.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(coverStack)
        let bodyArea = UIView()
        for view in [body, cover] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bodyArea.addSubview(view)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyArea.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyArea.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyArea.trailingAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: bodyArea.bottomAnchor),
            cover.topAnchor.constraint(equalTo: bodyArea.topAnchor),
            cover.bottomAnchor.constraint(equalTo: bodyArea.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: bodyArea.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: bodyArea.trailingAnchor),
            coverStack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverStack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        bodyArea.setContentHuggingPriority(.defaultLow, for: .vertical)

        gif.isHidden = true
        gif.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let stack = UIStackView(arrangedSubviews: [header, bodyArea, gif, footer])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        accessibilityIdentifier = "trakt.comment.\(commentID)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the comment as it stands now, in place, so a focused card keeps the focus while its counts change.
    func apply(comment: TraktComment, isRevealed: Bool, isLiked: Bool, summary: TraktReactionSummary?, mine: Set<TraktReaction>, isMine: Bool) {
        avatar.configure(comment.user)
        name.text = isMine ? "\(comment.user.displayName) (\(TraktCommunityCopy.you))" : comment.user.displayName
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in Self.tags(comment) { tags.addArrangedSubview(Self.tagLabel(tag)) }
        meta.text = [comment.authorRating.map { "★ \($0)/10" }, TraktCommunityCopy.age(comment.createdAt)].compactMap { $0 }.joined(separator: "  ·  ")
        let text = TraktCommentText(comment.text)
        body.attributedText = TraktCommentTextFormatter.attributed(text, font: Theme.Font.callout, color: Theme.Color.label, revealed: isRevealed, lineSpacing: 4)
        let covered = comment.isSpoiler && !isRevealed
        body.alpha = covered ? 0 : 1
        cover.isHidden = !covered
        let hasGIF = comment.gifURL != nil && !covered
        gif.isHidden = !hasGIF
        gif.show(hasGIF ? comment.gifURL : nil)
        body.numberOfLines = hasGIF ? 2 : 5
        footer.attributedText = Self.footer(comment: comment, isLiked: isLiked, summary: summary, mine: mine)
        accessibilityLabel = TraktCommunityCopy.accessibilityLabel(comment, hidingSpoilers: !isRevealed)
        accessibilityHint = covered || (text.hasInlineSpoilers && !isRevealed) ? TraktCommunityCopy.pressToReveal : nil
    }

    static func tags(_ comment: TraktComment) -> [String] {
        var tags: [String] = []
        if comment.user.isVIP { tags.append(TraktCommunityCopy.vip) }
        if comment.isReview { tags.append(TraktCommunityCopy.review.uppercased()) }
        if comment.isSpoiler { tags.append(TraktCommunityCopy.spoiler.uppercased()) }
        return tags
    }

    private static func tagLabel(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = TVFont.eyebrow
        label.textColor = text == TraktCommunityCopy.vip ? Theme.Color.accent : (text == TraktCommunityCopy.spoiler.uppercased() ? .systemRed : .systemTeal)
        return label
    }

    /// "♥ 12   💬 3   😂 5 ❤️ 2", the viewer's like and reactions in accent.
    static func footer(comment: TraktComment, isLiked: Bool, summary: TraktReactionSummary?, mine: Set<TraktReaction>) -> NSAttributedString {
        let font = TVFont.cardSubtitle
        let result = NSMutableAttributedString()
        let heart = NSTextAttachment(image: UIImage(systemName: isLiked ? "heart.fill" : "heart", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(isLiked ? .systemPink : Theme.Color.labelSecondary, renderingMode: .alwaysOriginal) ?? UIImage())
        result.append(NSAttributedString(attachment: heart))
        result.append(NSAttributedString(string: " \(Formatters.compactCount(comment.likeCount))     ", attributes: [.font: font, .foregroundColor: Theme.Color.labelSecondary]))
        let bubble = NSTextAttachment(image: UIImage(systemName: "bubble.left", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(Theme.Color.labelSecondary, renderingMode: .alwaysOriginal) ?? UIImage())
        result.append(NSAttributedString(attachment: bubble))
        result.append(NSAttributedString(string: " \(Formatters.compactCount(comment.replyCount))", attributes: [.font: font, .foregroundColor: Theme.Color.labelSecondary]))
        for (reaction, count) in (summary?.ranked ?? []).prefix(3) {
            let color = mine.contains(reaction) ? Theme.Color.accentText : Theme.Color.labelSecondary
            result.append(NSAttributedString(string: "     \(reaction.emoji) \(Formatters.compactCount(count))", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

/// A card at the end of the comments shelf: Write a Review, See All, or for a viewer without Pro, Unlock.
final class TVCommunityActionCard: TVFocusableSurface {
    enum Kind {
        case write
        case seeAll(Int)
        case unlock(Int)
    }

    private let subtitleLabel = UILabel()
    private let titleLabel = UILabel()
    /// Which card of the shelf this is, kept while what it shows changes, such as Unlock turning into See All after a purchase.
    var slot = ""

    init(_ kind: Kind) {
        super.init(cornerRadius: Theme.Radius.l)
        apply(kind)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `kind` with its count, in place.
    func apply(_ kind: Kind) {
        contentView.subviews.filter { $0 is UIStackView }.forEach { $0.removeFromSuperview() }
        let symbol: String
        let title: String
        let subtitle: String?
        switch kind {
        case .write:
            symbol = "square.and.pencil"
            title = TraktCommunityCopy.writeReview
            subtitle = TraktCommunityCopy.emptyMessage
            accessibilityIdentifier = "trakt.community.write"
        case .seeAll(let count):
            symbol = "bubble.left.and.bubble.right.fill"
            title = TraktCommunityCopy.seeAll
            subtitle = TraktCommunityCopy.commentCount(count)
            accessibilityIdentifier = "trakt.community.seeAll"
        case .unlock(let count):
            symbol = "lock.open.fill"
            title = TraktCommunityCopy.unlockTitle
            subtitle = TraktCommunityCopy.readAll(count)
            accessibilityIdentifier = "trakt.community.unlock"
        }
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        titleLabel.text = title
        titleLabel.font = Theme.Font.title3
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        subtitleLabel.text = subtitle
        subtitleLabel.font = TVFont.cardSubtitle
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.numberOfLines = 2
        subtitleLabel.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}
