import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// A frosted cover over a comment marked as a spoiler, saying so and how to read it anyway.
final class TraktSpoilerCoverView: UIVisualEffectView {
    init(compact: Bool = false) {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Theme.Radius.s
        layer.cornerCurve = .continuous
        clipsToBounds = true
        let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: compact ? .subheadline : .title3)))
        icon.tintColor = Theme.Color.labelSecondary
        let title = UILabel()
        title.text = TraktCommunityCopy.spoilerCover
        title.font = Theme.Font.subheadlineSemibold
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        let hint = UILabel()
        hint.text = TraktCommunityCopy.tapToReveal
        hint.font = Theme.Font.caption1Regular
        hint.textColor = Theme.Color.labelSecondary
        hint.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [icon, title, hint])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Space.s),
        ])
        isAccessibilityElement = true
        accessibilityLabel = TraktCommunityCopy.spoilerCover
        accessibilityHint = TraktCommunityCopy.tapToReveal
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The small capsules beside a member's name: VIP, Director, Review, Spoiler.
enum TraktTag {
    case vip, director, review, spoiler, edited

    var text: String {
        switch self {
        case .vip: return TraktCommunityCopy.vip
        case .director: return TraktCommunityCopy.director
        case .review: return TraktCommunityCopy.review
        case .spoiler: return TraktCommunityCopy.spoiler
        case .edited: return TraktCommunityCopy.edited
        }
    }

    var color: UIColor {
        switch self {
        case .vip: return Theme.Color.accent
        case .director: return .systemPurple
        case .review: return .systemTeal
        case .spoiler: return .systemRed
        case .edited: return Theme.Color.labelTertiary
        }
    }

    @MainActor
    func makeView() -> UIView {
        let label = UILabel()
        label.text = self == .edited ? text : text.uppercased()
        label.font = self == .edited ? Theme.Font.caption1Regular : Theme.Font.badge
        label.textColor = self == .edited ? Theme.Color.labelTertiary : color
        label.adjustsFontForContentSizeCategory = true
        guard self != .edited else { return label }
        let capsule = UIView()
        capsule.backgroundColor = color.withAlphaComponent(0.16)
        capsule.layer.cornerRadius = 6
        capsule.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -6),
        ])
        capsule.setContentHuggingPriority(.required, for: .horizontal)
        capsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        return capsule
    }
}

/// A comment's footer: the heart with its likes, the replies, the reactions people left as emoji with their counts, and a
/// button that opens the reaction picker.
final class TraktCommentFooterView: UIView {
    struct State {
        var commentID: Int
        var likeCount: Int
        var isLiked: Bool
        var replyCount: Int
        var summary: TraktReactionSummary?
        var mine: Set<TraktReaction>
        var showsReplies = true
        var maxReactions = 3
    }

    var onLike: (() -> Void)?
    var onReplies: (() -> Void)?
    var onReact: ((TraktReaction) -> Void)?

    private let likeButton = UIButton(configuration: .plain())
    private let replyButton = UIButton(configuration: .plain())
    private let reactions = UIStackView()
    private let reactButton = UIButton(configuration: .plain())
    private var state: State?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for button in [likeButton, replyButton] {
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 8)
            configuration.imagePadding = 5
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
            button.configuration = configuration
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        likeButton.addAction(UIAction { [weak self] _ in self?.onLike?() }, for: .primaryActionTriggered)
        replyButton.addAction(UIAction { [weak self] _ in self?.onReplies?() }, for: .primaryActionTriggered)
        likeButton.accessibilityIdentifier = "trakt.comment.like"
        replyButton.accessibilityIdentifier = "trakt.comment.replies"

        var react = UIButton.Configuration.plain()
        react.image = UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .large))
        react.baseForegroundColor = Theme.Color.labelSecondary
        react.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 2)
        reactButton.configuration = react
        reactButton.showsMenuAsPrimaryAction = true
        reactButton.accessibilityLabel = TraktCommunityCopy.react
        reactButton.accessibilityIdentifier = "trakt.comment.react"
        reactButton.setContentHuggingPriority(.required, for: .horizontal)

        reactions.axis = .horizontal
        reactions.spacing = 4
        reactions.alignment = .center
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [likeButton, replyButton, spacer, reactions, reactButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        let previous = self.state
        self.state = state
        var like = likeButton.configuration ?? .plain()
        like.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        like.baseForegroundColor = state.isLiked ? .systemPink : Theme.Color.labelSecondary
        like.attributedTitle = AttributedString(Formatters.compactCount(state.likeCount), attributes: AttributeContainer([.font: Theme.Font.footnoteSemibold]))
        likeButton.configuration = like
        likeButton.accessibilityLabel = state.isLiked ? TraktCommunityCopy.unlike : TraktCommunityCopy.like
        likeButton.accessibilityValue = TraktCommunityCopy.likeCount(state.likeCount)
        if let previous, previous.commentID == state.commentID, !previous.isLiked, state.isLiked, !UIAccessibility.isReduceMotionEnabled {
            likeButton.imageView?.addSymbolEffect(.bounce)
        }

        replyButton.isHidden = !state.showsReplies
        var reply = replyButton.configuration ?? .plain()
        reply.image = UIImage(systemName: "bubble.left")
        reply.baseForegroundColor = Theme.Color.labelSecondary
        reply.attributedTitle = AttributedString(Formatters.compactCount(state.replyCount), attributes: AttributeContainer([.font: Theme.Font.footnoteSemibold]))
        replyButton.configuration = reply
        replyButton.accessibilityLabel = TraktCommunityCopy.replyCount(state.replyCount)

        reactions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (reaction, count) in (state.summary?.ranked ?? []).prefix(state.maxReactions) {
            reactions.addArrangedSubview(Self.pill(reaction, count: count, mine: state.mine.contains(reaction)) { [weak self] in self?.onReact?(reaction) })
        }
        reactButton.menu = TraktReactionMenu.menu(mine: state.mine) { [weak self] reaction in self?.onReact?(reaction) }
    }

    /// One reaction with its count; the viewer's own are tinted.
    static func pill(_ reaction: TraktReaction, count: Int, mine: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString("\(reaction.emoji) \(Formatters.compactCount(count))", attributes: AttributeContainer([
            .font: Theme.Font.caption1, .foregroundColor: mine ? Theme.Color.accentText : Theme.Color.labelSecondary,
        ]))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
        configuration.background.backgroundColor = mine ? Theme.Color.accentTint : Theme.Color.surfaceHigh.withAlphaComponent(0.6)
        configuration.background.strokeColor = mine ? Theme.Color.accent : .clear
        configuration.background.strokeWidth = mine ? 1 : 0
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            Haptics.selection()
            action()
        })
        button.accessibilityLabel = "\(reaction.title), \(count)"
        if mine { button.accessibilityTraits.insert(.selected) }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

/// The reactions as a menu: each emoji with its name, the viewer's own checked.
@MainActor
enum TraktReactionMenu {
    static func menu(mine: Set<TraktReaction>, onPick: @escaping (TraktReaction) -> Void) -> UIMenu {
        let actions = TraktReaction.allCases.map { reaction in
            UIAction(title: reaction.title, image: TraktEmojiImage.image(reaction.emoji), state: mine.contains(reaction) ? .on : .off) { _ in
                Haptics.selection()
                onPick(reaction)
            }
        }
        let menu = UIMenu(title: TraktCommunityCopy.react, options: .displayInline, children: actions)
        menu.preferredElementSize = .medium
        return menu
    }
}

/// A rounded raised surface with a hairline edge, behind the community's cards.
final class TraktCardBackground: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = Theme.Radius.m + 4
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.separator.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TraktCardBackground, _: UITraitCollection) in
            view.layer.borderColor = Theme.Color.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
