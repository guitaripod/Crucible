import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
@preconcurrency import UIKit

/// The pulse of a title's community, at the top of its Community section: Trakt's score with how its voters spread across the
/// ten points, how many watch, play, list and love it, and who is watching right now.
struct TraktPulseConfiguration: UIContentConfiguration {
    var score: TraktScore?
    var distribution: TraktRatingDistribution?
    var stats: TraktTitleStats?
    var watching: [TraktUser] = []
    var animatesBars = true
    var onWatching: (() -> Void)?

    func makeContentView() -> UIView & UIContentView { TraktPulseContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktPulseConfiguration { self }
}

final class TraktPulseContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = TraktCardBackground()
    private let mark = UIImageView()
    private let scoreLabel = UILabel()
    private let votesLabel = UILabel()
    private let histogram = TraktHistogramView()
    private let tiles = UIStackView()
    private let live = TraktLivePill()
    private let scoreBlock = UIStackView()

    init(configuration: TraktPulseConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        mark.image = BrandMark.trakt.image
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 22), mark.heightAnchor.constraint(equalToConstant: 22)])
        scoreLabel.font = Theme.Font.scaled(.largeTitle, UIFont.systemFont(ofSize: 38, weight: .heavy).withSystemDesign(.rounded), maximum: 56)
        scoreLabel.adjustsFontForContentSizeCategory = true
        scoreLabel.textColor = Theme.Color.label
        votesLabel.font = Theme.Font.caption1Regular
        votesLabel.textColor = Theme.Color.labelSecondary
        votesLabel.adjustsFontForContentSizeCategory = true
        votesLabel.numberOfLines = 2
        let markRow = UIStackView(arrangedSubviews: [mark, scoreLabel])
        markRow.spacing = 8
        markRow.alignment = .center
        scoreBlock.addArrangedSubview(markRow)
        scoreBlock.addArrangedSubview(votesLabel)
        scoreBlock.axis = .vertical
        scoreBlock.spacing = 2
        scoreBlock.alignment = .leading
        scoreBlock.setContentHuggingPriority(.required, for: .horizontal)
        scoreBlock.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = UIStackView(arrangedSubviews: [scoreBlock, histogram])
        top.spacing = Theme.Space.l
        top.alignment = .bottom

        tiles.axis = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = Theme.Space.xs

        live.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktPulseConfiguration)?.onWatching?() }, for: .primaryActionTriggered)

        let divider = UIView()
        divider.backgroundColor = Theme.Color.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = UIStackView(arrangedSubviews: [top, divider, tiles, live])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.s, after: tiles)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m + 2),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m + 2),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(Theme.Space.m + 2)),
        ])
        accessibilityIdentifier = "trakt.community.pulse"
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktPulseConfiguration else { return }
        scoreBlock.isHidden = config.score == nil
        if let score = config.score {
            scoreLabel.text = TraktCopy.value(score)
            votesLabel.text = TraktCopy.detail(score)
            scoreBlock.isAccessibilityElement = true
            scoreBlock.accessibilityLabel = TraktCopy.accessibilityLabel(score)
        }
        histogram.isHidden = config.distribution == nil
        if let distribution = config.distribution { histogram.show(distribution, animated: config.animatesBars) }

        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let stats = config.stats {
            var entries: [(String, Int, String)] = [
                ("eye.fill", stats.watchers, TraktCommunityCopy.statWatchers),
                ("play.fill", stats.plays, TraktCommunityCopy.statPlays),
                ("list.bullet.rectangle.fill", stats.lists, TraktCommunityCopy.statLists),
            ]
            if let favorited = stats.favorited, favorited > 0 {
                entries.append(("heart.fill", favorited, TraktCommunityCopy.statFavorites))
            } else {
                entries.append(("bubble.left.fill", stats.comments, TraktCommunityCopy.statComments))
            }
            entries.forEach { tiles.addArrangedSubview(Self.tile(symbol: $0.0, value: $0.1, label: $0.2)) }
        }
        tiles.isHidden = config.stats == nil
        live.isHidden = config.watching.isEmpty
        live.configure(config.watching)
    }

    private static func tile(symbol: String, value: Int, label: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .center
        let number = UILabel()
        number.text = Formatters.compactCount(value)
        number.font = Theme.Font.scaled(.headline, UIFont.systemFont(ofSize: 17, weight: .bold).withSystemDesign(.rounded), maximum: 26)
        number.adjustsFontForContentSizeCategory = true
        number.textColor = Theme.Color.label
        let caption = UILabel()
        caption.text = label
        caption.font = Theme.Font.caption2Regular
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.labelSecondary
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.8
        let stack = UIStackView(arrangedSubviews: [icon, number, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(label), \(Formatters.compactCount(value))"
        return stack
    }
}

/// "● 5 watching now" with the faces of who is watching, a live dot that breathes, and a tap that lists them.
final class TraktLivePill: UIControl {
    private let dot = UIView()
    private let faces = UIStackView()
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        faces.axis = .horizontal
        faces.spacing = -8
        label.font = Theme.Font.footnoteSemibold
        label.textColor = Theme.Color.label
        label.adjustsFontForContentSizeCategory = true
        chevron.tintColor = Theme.Color.labelTertiary
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [dot, label, spacer, faces, chevron])
        row.spacing = 8
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "trakt.community.watching"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        dot.layer.removeAnimation(forKey: "breathe")
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.25
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer.add(breathe, forKey: "breathe")
    }

    func configure(_ users: [TraktUser]) {
        label.text = TraktCommunityCopy.watchingNow(users.count)
        accessibilityLabel = TraktCommunityCopy.watchingNow(users.count)
        faces.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for user in users.prefix(4) {
            let avatar = TraktAvatarView(diameter: 22)
            avatar.configure(user)
            avatar.layer.borderWidth = 2
            avatar.layer.borderColor = Theme.Color.surfaceRaised.cgColor
            faces.addArrangedSubview(avatar)
        }
    }
}

/// What people say about a title, as Trakt distils it from comments: what they loved and what not so much, each a chip that
/// opens the comments it came from. Without Pro the chips sit under frosted glass with a way to unlock them.
struct TraktSentimentsConfiguration: UIContentConfiguration {
    var sentiments: TraktSentiments
    var isLocked: Bool
    var onAspect: ((TraktSentiments.Aspect) -> Void)?
    var onUnlock: (() -> Void)?

    func makeContentView() -> UIView & UIContentView { TraktSentimentsContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktSentimentsConfiguration { self }
}

final class TraktSentimentsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = TraktCardBackground()
    private let groups = UIStackView()
    private let footnote = UILabel()
    private let veil = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let unlockButton = UIButton(configuration: .plain())
    private let lockLabel = UILabel()
    private var shown: (sentiments: TraktSentiments, isLocked: Bool, words: [String])?

    init(configuration: TraktSentimentsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let sparkle = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline)))
        sparkle.tintColor = Theme.Color.accent
        sparkle.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.text = TraktCommunityCopy.whatPeopleSay
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [sparkle, title])
        header.spacing = 8
        header.alignment = .center
        title.accessibilityTraits = .header

        groups.axis = .vertical
        groups.spacing = Theme.Space.s
        footnote.font = Theme.Font.caption1Regular
        footnote.textColor = Theme.Color.labelTertiary
        footnote.adjustsFontForContentSizeCategory = true
        footnote.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [header, groups, footnote])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        veil.translatesAutoresizingMaskIntoConstraints = false
        veil.layer.cornerRadius = Theme.Radius.s
        veil.layer.cornerCurve = .continuous
        veil.clipsToBounds = true
        card.addSubview(veil)
        lockLabel.text = TraktCommunityCopy.lockedSentiments
        lockLabel.font = Theme.Font.footnote
        lockLabel.textColor = Theme.Color.label
        lockLabel.numberOfLines = 0
        lockLabel.textAlignment = .center
        lockLabel.adjustsFontForContentSizeCategory = true
        var unlock = Glass.prominentButton { .filled() }
        unlock.title = TraktCommunityCopy.unlockAction
        unlock.image = UIImage(systemName: "lock.open.fill")
        unlock.imagePadding = 6
        unlock.cornerStyle = .capsule
        unlock.baseBackgroundColor = Theme.Color.accent
        unlock.baseForegroundColor = Theme.Color.onAccent
        unlockButton.configuration = unlock
        unlockButton.accessibilityIdentifier = "trakt.community.unlockSentiments"
        unlockButton.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktSentimentsConfiguration)?.onUnlock?() }, for: .primaryActionTriggered)
        let lockStack = UIStackView(arrangedSubviews: [lockLabel, unlockButton])
        lockStack.axis = .vertical
        lockStack.alignment = .center
        lockStack.spacing = Theme.Space.s
        lockStack.translatesAutoresizingMaskIntoConstraints = false
        veil.contentView.addSubview(lockStack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m + 2),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(Theme.Space.m + 2)),
            veil.topAnchor.constraint(equalTo: groups.topAnchor, constant: -6),
            veil.bottomAnchor.constraint(equalTo: footnote.bottomAnchor, constant: 6),
            veil.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            veil.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            lockStack.centerYAnchor.constraint(equalTo: veil.contentView.centerYAnchor),
            lockStack.leadingAnchor.constraint(equalTo: veil.contentView.leadingAnchor, constant: Theme.Space.m),
            lockStack.trailingAnchor.constraint(equalTo: veil.contentView.trailingAnchor, constant: -Theme.Space.m),
            lockStack.topAnchor.constraint(greaterThanOrEqualTo: veil.contentView.topAnchor, constant: 6),
        ])
        accessibilityIdentifier = "trakt.community.sentiments"
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktSentimentsConfiguration else { return }
        veil.isHidden = !config.isLocked
        groups.accessibilityElementsHidden = config.isLocked
        footnote.text = TraktCommunityCopy.sentimentSource(config.sentiments.commentCount)
        let words = (config.sentiments.good + config.sentiments.bad).map(TraktSentimentsTranslation.text)
        if let shown, shown.sentiments == config.sentiments, shown.isLocked == config.isLocked, shown.words == words { return }
        shown = (config.sentiments, config.isLocked, words)
        groups.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !config.sentiments.good.isEmpty {
            groups.addArrangedSubview(group(TraktCommunityCopy.theGood, symbol: "hand.thumbsup.fill", tint: .systemGreen, aspects: config.sentiments.good, enabled: !config.isLocked))
        }
        if !config.sentiments.bad.isEmpty {
            groups.addArrangedSubview(group(TraktCommunityCopy.theBad, symbol: "hand.thumbsdown.fill", tint: .systemOrange, aspects: config.sentiments.bad, enabled: !config.isLocked))
        }
    }

    private func group(_ title: String, symbol: String, tint: UIColor, aspects: [TraktSentiments.Aspect], enabled: Bool) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)))
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.text = title.uppercased()
        label.font = Theme.Font.caption2
        label.textColor = tint
        label.adjustsFontForContentSizeCategory = true
        let heading = UIStackView(arrangedSubviews: [icon, label])
        heading.spacing = 5
        heading.alignment = .center

        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 6
        for aspect in aspects {
            var configuration = UIButton.Configuration.plain()
            var title = AttributedString(TraktSentimentsTranslation.text(aspect), attributes: AttributeContainer([.font: Theme.Font.footnoteSemibold, .foregroundColor: Theme.Color.label]))
            if !aspect.commentIDs.isEmpty {
                title += AttributedString("  \(aspect.commentIDs.count)", attributes: AttributeContainer([.font: Theme.Font.caption1Regular, .foregroundColor: tint]))
            }
            configuration.attributedTitle = title
            configuration.background.backgroundColor = tint.withAlphaComponent(0.14)
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
            let chip = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                Haptics.selection()
                (self?.configuration as? TraktSentimentsConfiguration)?.onAspect?(aspect)
            })
            chip.isEnabled = enabled
            chip.accessibilityIdentifier = "trakt.aspect"
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            chips.addArrangedSubview(chip)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        chips.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(chips)
        NSLayoutConstraint.activate([
            chips.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: chips.heightAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [heading, scroll])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }
}

/// The last card of the comments rail for a viewer without Pro: how many comments wait, and the way to read them.
struct TraktUnlockCardConfiguration: UIContentConfiguration {
    var count: Int

    func makeContentView() -> UIView & UIContentView { TraktUnlockCardContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktUnlockCardConfiguration { self }
}

final class TraktUnlockCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let gradient = CAGradientLayer()
    private let subtitle = UILabel()

    init(configuration: TraktUnlockCardConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        layer.cornerRadius = Theme.Radius.m + 4
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        gradient.colors = [Theme.Color.emberTop, Theme.Color.emberMid, Theme.Color.emberBottom].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.text.bubble.right.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title1)))
        icon.tintColor = Theme.Color.emberEyebrow
        let title = UILabel()
        title.text = TraktCommunityCopy.unlockTitle
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.onArt
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        subtitle.font = Theme.Font.subheadline
        subtitle.textColor = Theme.Color.onArtSecondary
        subtitle.numberOfLines = 0
        subtitle.adjustsFontForContentSizeCategory = true
        let pill = UILabel()
        pill.text = "  \(TraktCommunityCopy.unlockAction)  "
        pill.font = Theme.Font.subheadlineSemibold
        pill.textColor = Theme.Color.onAccent
        pill.backgroundColor = Theme.Color.emberEyebrow
        pill.layer.cornerRadius = 16
        pill.layer.masksToBounds = true
        pill.textAlignment = .center
        pill.adjustsFontForContentSizeCategory = true
        pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle, spacer, pill])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m + 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Theme.Space.m + 2)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m + 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Theme.Space.m + 2)),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "trakt.community.unlock"
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    private func apply() {
        guard let config = configuration as? TraktUnlockCardConfiguration else { return }
        subtitle.text = TraktCommunityCopy.readAll(config.count)
        accessibilityLabel = "\(TraktCommunityCopy.unlockTitle), \(TraktCommunityCopy.readAll(config.count)), \(TraktCommunityCopy.unlockAction)"
    }
}

/// Write a Review and See All under a title's comments, with a line when nobody has written one yet.
struct TraktCommunityActionsConfiguration: UIContentConfiguration {
    var commentCount: Int
    var showsSeeAll: Bool
    var note: String?
    var onWrite: (() -> Void)?
    var onSeeAll: (() -> Void)?

    func makeContentView() -> UIView & UIContentView { TraktCommunityActionsContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> TraktCommunityActionsConfiguration { self }
}

final class TraktCommunityActionsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let write = UIButton(configuration: .plain())
    private let seeAll = UIButton(configuration: .plain())
    private let note = UILabel()

    init(configuration: TraktCommunityActionsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        var writeConfig = Glass.prominentButton { .filled() }
        writeConfig.title = TraktCommunityCopy.writeReview
        writeConfig.image = UIImage(systemName: "square.and.pencil")
        writeConfig.imagePadding = 8
        writeConfig.cornerStyle = .capsule
        writeConfig.baseBackgroundColor = Theme.Color.accent
        writeConfig.baseForegroundColor = Theme.Color.onAccent
        writeConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        write.configuration = writeConfig
        write.accessibilityIdentifier = "trakt.community.write"
        write.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktCommunityActionsConfiguration)?.onWrite?() }, for: .primaryActionTriggered)

        var allConfig = Glass.glassButton { .tinted() }
        allConfig.image = UIImage(systemName: "bubble.left.and.bubble.right")
        allConfig.imagePadding = 8
        allConfig.cornerStyle = .capsule
        allConfig.baseForegroundColor = Theme.Color.label
        allConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        seeAll.configuration = allConfig
        seeAll.accessibilityIdentifier = "trakt.community.seeAll"
        seeAll.addAction(UIAction { [weak self] _ in (self?.configuration as? TraktCommunityActionsConfiguration)?.onSeeAll?() }, for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [write, seeAll])
        buttons.spacing = Theme.Space.s
        buttons.distribution = .fillEqually
        note.font = Theme.Font.footnote
        note.textColor = Theme.Color.labelSecondary
        note.numberOfLines = 0
        note.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [note, buttons])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? TraktCommunityActionsConfiguration else { return }
        seeAll.isHidden = !config.showsSeeAll
        var allConfig = seeAll.configuration
        allConfig?.title = config.commentCount > 0 ? "\(TraktCommunityCopy.seeAll) (\(Formatters.compactCount(config.commentCount)))" : TraktCommunityCopy.seeAll
        seeAll.configuration = allConfig
        note.text = config.note
        note.isHidden = config.note == nil
    }
}
