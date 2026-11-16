import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
@preconcurrency import UIKit

/// One Trakt comment, drawn four ways: a card in a title's rail, a row of the full list, the comment a thread is about, and
/// a reply under it. It shows who wrote it with their rating of the title, the text with spoilers covered until revealed,
/// in the reader's language when it was written in another, and the footer with likes, replies and reactions.
struct TraktCommentConfiguration: UIContentConfiguration {
    enum Style: Equatable {
        case card
        case row
        case root
        case reply
    }

    var comment: TraktComment
    var style: Style
    var isMine = false
    var isRevealed = false
    var isLiked = false
    var summary: TraktReactionSummary?
    var mine: Set<TraktReaction> = []
    var menu: UIMenu?
    var onLike: (() -> Void)?
    var onReplies: (() -> Void)?
    var onReact: ((TraktReaction) -> Void)?
    var onReveal: (() -> Void)?
    var onAuthor: (() -> Void)?
    var onLink: ((URL) -> Void)?

    func makeContentView() -> UIView & UIContentView {
        TraktCommentContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TraktCommentConfiguration {
        self
    }

    /// How many lines of text the style shows before the rest waits in the thread.
    var bodyLines: Int {
        switch style {
        case .card: return 6
        case .row: return 12
        case .root, .reply: return 0
        }
    }

    /// Whether the text is covered: the whole comment is a spoiler and the viewer has not revealed it.
    var isCovered: Bool { comment.isSpoiler && !isRevealed }
}

final class TraktCommentContentView: UIView, UIContentView, UITextViewDelegate {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = TraktCardBackground()
    private let avatar: TraktAvatarView
    private let avatarButton = UIButton(configuration: .plain())
    private let nameLabel = UILabel()
    private let tags = UIStackView()
    private let metaLabel = UILabel()
    private let moreButton = UIButton(configuration: .plain())
    private let body = UITextView()
    private let bodyContainer = UIView()
    private let cover = TraktSpoilerCoverView(compact: true)
    private let footer = TraktCommentFooterView()
    private let translationButton = TranslationLineButton()
    private var translationObservers: [NSObjectProtocol] = []
    private let gif = TraktGIFView(cornerRadius: Theme.Radius.s)
    private var bodyHeight: NSLayoutConstraint?
    private var gifHeight: NSLayoutConstraint?
    private var coverHeight: NSLayoutConstraint?
    private var revealTap: UITapGestureRecognizer?

    init(configuration: TraktCommentConfiguration) {
        self.configuration = configuration
        avatar = TraktAvatarView(diameter: configuration.style == .reply ? 30 : (configuration.style == .root ? 44 : 36))
        super.init(frame: .zero)
        preferContentHeight()
        build(configuration.style)
        apply()
        observeTranslations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        translationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows a translation as it lands, or the original when the reader switches back, growing the row to fit.
    private func observeTranslations() {
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let comment = self.currentConfiguration?.comment else { return }
                guard key == nil || key == TranslationCenter.key(comment) else { return }
                self.apply()
                self.invalidateIntrinsicContentSize()
            }
        }
        translationObservers = [
            center.addObserver(forName: .translationChanged, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .translationPreferencesChanged, object: nil, queue: .main, using: refresh),
        ]
    }

    private func build(_ style: TraktCommentConfiguration.Style) {
        let isCard = style == .card
        if isCard {
            card.translatesAutoresizingMaskIntoConstraints = false
            addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor),
                card.bottomAnchor.constraint(equalTo: bottomAnchor),
                card.leadingAnchor.constraint(equalTo: leadingAnchor),
                card.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatar)
        avatar.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: avatarButton.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
            avatar.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
        ])
        avatarButton.addAction(UIAction { [weak self] _ in self?.currentConfiguration?.onAuthor?() }, for: .primaryActionTriggered)
        avatarButton.accessibilityIdentifier = "trakt.comment.author"

        nameLabel.font = style == .root ? Theme.Font.headline : Theme.Font.subheadlineSemibold
        nameLabel.textColor = Theme.Color.label
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tags.axis = .horizontal
        tags.spacing = 4
        tags.alignment = .center
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, tags])
        nameRow.axis = .horizontal
        nameRow.spacing = 6
        nameRow.alignment = .center
        metaLabel.font = Theme.Font.caption1Regular
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.adjustsFontForContentSizeCategory = true
        let names = UIStackView(arrangedSubviews: [nameRow, metaLabel])
        names.axis = .vertical
        names.spacing = 1
        names.alignment = .leading

        var more = UIButton.Configuration.plain()
        more.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium))
        more.baseForegroundColor = Theme.Color.labelSecondary
        more.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0)
        moreButton.configuration = more
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = String(localized: "More")
        moreButton.accessibilityIdentifier = "trakt.comment.more"
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        moreButton.isHidden = isCard

        let header = UIStackView(arrangedSubviews: [avatarButton, names, moreButton])
        header.axis = .horizontal
        header.spacing = Theme.Space.s - 2
        header.alignment = .center
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)

        body.isEditable = false
        body.isScrollEnabled = false
        body.isSelectable = style == .root || style == .reply
        body.backgroundColor = .clear
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        body.textContainer.lineBreakMode = .byTruncatingTail
        body.adjustsFontForContentSizeCategory = true
        body.delegate = self
        body.translatesAutoresizingMaskIntoConstraints = false
        body.accessibilityIdentifier = "trakt.comment.text"
        bodyContainer.addSubview(body)
        cover.isHidden = true
        bodyContainer.addSubview(cover)
        let bottom = body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        bottom.priority = isCard ? .defaultLow : .required
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            bottom,
            body.bottomAnchor.constraint(lessThanOrEqualTo: bodyContainer.bottomAnchor),
            cover.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            cover.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
        ])
        coverHeight = cover.heightAnchor.constraint(greaterThanOrEqualToConstant: 76)
        if isCard {
            let height = bodyContainer.heightAnchor.constraint(equalToConstant: 100)
            height.isActive = true
            bodyHeight = height
        }
        let coverTap = UITapGestureRecognizer(target: nil, action: nil)
        coverTap.addTarget(self, action: #selector(revealTapped))
        cover.addGestureRecognizer(coverTap)
        let textTap = UITapGestureRecognizer(target: nil, action: nil)
        textTap.addTarget(self, action: #selector(revealTapped))
        body.addGestureRecognizer(textTap)
        revealTap = textTap

        translationButton.accessibilityIdentifier = "trakt.comment.translation"
        translationButton.addAction(UIAction { [weak self] _ in self?.translationTapped() }, for: .primaryActionTriggered)

        footer.onLike = { [weak self] in self?.currentConfiguration?.onLike?() }
        footer.onReplies = { [weak self] in self?.currentConfiguration?.onReplies?() }
        footer.onReact = { [weak self] reaction in self?.currentConfiguration?.onReact?(reaction) }

        gif.isHidden = true
        let gifHeight = gif.heightAnchor.constraint(equalToConstant: 180)
        gifHeight.isActive = true
        self.gifHeight = gifHeight
        let content = UIStackView(arrangedSubviews: [header, bodyContainer, translationButton, gif, footer])
        content.axis = .vertical
        content.spacing = style == .root ? Theme.Space.s : Theme.Space.xs + 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset: NSDirectionalEdgeInsets
        switch style {
        case .card: inset = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 14)
        case .row: inset = NSDirectionalEdgeInsets(top: 14, leading: Theme.Space.m, bottom: 4, trailing: Theme.Space.m)
        case .root: inset = NSDirectionalEdgeInsets(top: Theme.Space.s, leading: Theme.Space.m, bottom: 4, trailing: Theme.Space.m)
        case .reply: inset = NSDirectionalEdgeInsets(top: 12, leading: Theme.Space.m + 20, bottom: 2, trailing: Theme.Space.m)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset.bottom),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset.leading),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset.trailing),
        ])
        if style == .reply {
            let thread = UIView()
            thread.backgroundColor = Theme.Color.separator
            thread.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thread)
            NSLayoutConstraint.activate([
                thread.widthAnchor.constraint(equalToConstant: 2),
                thread.topAnchor.constraint(equalTo: topAnchor),
                thread.bottomAnchor.constraint(equalTo: bottomAnchor),
                thread.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m + 6),
            ])
        }
    }

    private var currentConfiguration: TraktCommentConfiguration? { configuration as? TraktCommentConfiguration }

    private func apply() {
        guard let config = currentConfiguration else { return }
        let translation = TranslationCenter.shared.presentation(for: config.comment)
        var comment = config.comment
        if translation.showsTranslation, let translated = translation.translation { comment.text = translated }
        avatar.configure(comment.user)
        avatarButton.accessibilityLabel = comment.user.displayName
        nameLabel.text = config.isMine ? "\(comment.user.displayName) (\(TraktCommunityCopy.you))" : comment.user.displayName
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var shownTags: [TraktTag] = []
        if comment.user.isVIP { shownTags.append(.vip) }
        if comment.user.isDirector { shownTags.append(.director) }
        if comment.isReview { shownTags.append(.review) }
        if comment.isSpoiler { shownTags.append(.spoiler) }
        if config.style == .card, translation.showsTranslation { shownTags.append(.translated) }
        shownTags.forEach { tags.addArrangedSubview($0.makeView()) }
        tags.isHidden = shownTags.isEmpty
        metaLabel.attributedText = meta(comment)
        moreButton.menu = config.menu
        moreButton.isHidden = config.style == .card || config.menu == nil

        let font: UIFont = config.style == .root ? Theme.Font.body : Theme.Font.callout
        let text = TraktCommentText(comment.text)
        body.attributedText = TraktCommentTextFormatter.attributed(text, font: font, color: Theme.Color.label, revealed: config.isRevealed)
        body.textContainer.maximumNumberOfLines = config.bodyLines
        body.isUserInteractionEnabled = !config.isCovered
        revealTap?.isEnabled = text.hasInlineSpoilers && !config.isRevealed
        cover.isHidden = !config.isCovered
        coverHeight?.isActive = config.isCovered
        body.alpha = config.isCovered ? 0 : 1
        layoutTranslation(translation, style: config.style)
        layoutAttachment(config, font: font)
        body.accessibilityLabel = config.isCovered ? TraktCommunityCopy.spoilerCover
            : (config.isRevealed ? text.plainText : text.textHidingSpoilers)
        body.accessibilityHint = text.hasInlineSpoilers && !config.isRevealed ? TraktCommunityCopy.hiddenSpoiler : nil

        footer.apply(.init(
            commentID: comment.id,
            likeCount: comment.likeCount,
            isLiked: config.isLiked,
            replyCount: comment.replyCount,
            summary: config.summary,
            mine: config.mine,
            showsReplies: config.style != .reply,
            maxReactions: config.style == .card ? 2 : 4
        ))
        accessibilityIdentifier = "trakt.comment.\(comment.id)"
    }

    /// Shares the room a card has between the text and an attached GIF, so a card keeps its height with or without one; a
    /// comment that is only a GIF gives it all the room. Rows and threads show the GIF under the text.
    private func layoutAttachment(_ config: TraktCommentConfiguration, font: UIFont) {
        let comment = config.comment
        let hasGIF = comment.gifURL != nil && !config.isCovered
        let hasText = !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        gif.isHidden = !hasGIF
        gif.show(hasGIF ? comment.gifURL : nil)
        let line = ceil(font.lineHeight + 2)
        guard config.style == .card else {
            bodyContainer.isHidden = !hasText && !config.isCovered
            gifHeight?.constant = config.style == .reply ? 140 : 200
            return
        }
        let total = line * CGFloat(config.bodyLines)
        guard hasGIF else {
            bodyContainer.isHidden = false
            bodyHeight?.constant = total
            return
        }
        let textLines: CGFloat = hasText ? 2 : 0
        bodyContainer.isHidden = !hasText
        bodyHeight?.constant = line * textLines
        body.textContainer.maximumNumberOfLines = Int(textLines)
        gifHeight?.constant = total - line * textLines - (hasText ? Theme.Space.xs + 2 : 0)
    }

    /// The line under a row's text about its translation. A card has no room for it, so it carries the Translated tag and
    /// its menu instead.
    private func layoutTranslation(_ translation: TranslationCenter.Presentation, style: TraktCommentConfiguration.Style) {
        translationButton.show(style == .card ? .none : translation)
    }

    private func translationTapped() {
        guard let comment = currentConfiguration?.comment else { return }
        let center = TranslationCenter.shared
        switch translationButton.phase {
        case .offer, .failed: center.translate(comment)
        case .translated, .original: center.toggleOriginal(comment)
        case .translating, .none: break
        }
        Haptics.light()
    }

    private func meta(_ comment: TraktComment) -> NSAttributedString {
        let font = Theme.Font.caption1Regular
        let result = NSMutableAttributedString()
        if let rating = comment.authorRating {
            let star = NSTextAttachment(image: UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
                .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal) ?? UIImage())
            result.append(NSAttributedString(attachment: star))
            result.append(NSAttributedString(string: " \(rating)/10", attributes: [.font: Theme.Font.caption1, .foregroundColor: Theme.Color.label]))
            result.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: Theme.Color.labelTertiary]))
        }
        var tail = TraktCommunityCopy.age(comment.createdAt)
        if comment.wasEdited { tail += "  ·  " + TraktCommunityCopy.edited }
        result.append(NSAttributedString(string: tail, attributes: [.font: font, .foregroundColor: Theme.Color.labelSecondary]))
        return result
    }

    @objc private func revealTapped() {
        guard let config = currentConfiguration else { return }
        Haptics.light()
        config.onReveal?()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let open = currentConfiguration?.onLink else { return defaultAction }
        return UIAction { _ in open(url) }
    }
}
