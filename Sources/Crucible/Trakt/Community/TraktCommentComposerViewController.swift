import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import MidgarCore
@preconcurrency import UIKit

/// Writes a comment, a review or a reply on Trakt, or edits one of the viewer's own. It keeps Trakt's rules in view: a live
/// word count toward five words and toward a review at 200, a spoiler switch and a button that hides a part as a spoiler,
/// and warnings before Trakt would refuse it. What is written is kept as a draft until it is posted or thrown away.
final class TraktCommentComposerViewController: UIViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    enum Mode {
        case new(TraktCommunitySubject, titleName: String)
        case reply(TraktComment)
        case edit(TraktComment)
    }

    private let mode: Mode
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let spoilerButton = UIButton(configuration: .plain())
    private let hideButton = UIButton(configuration: .plain())
    private let translateButton = UIButton(configuration: .plain())
    private var isTranslating = false
    private let counter = UILabel()
    private let ring = TraktWordRing()
    private let bar = UIView()
    private var rules: UIView?
    private var postItem: UIBarButtonItem!
    private var isPosting = false
    private let original: String

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .edit(let comment): original = comment.text
        default: original = ""
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var draftKey: String? {
        switch mode {
        case .new(let subject, _): return TraktCommunity.draftKey(subject: subject)
        case .reply(let parent): return TraktCommunity.draftKey(replyingTo: parent.id)
        case .edit: return nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        let rulesItem = UIBarButtonItem(image: UIImage(systemName: "info.circle"), primaryAction: UIAction { [weak self] _ in self?.showRules() })
        rulesItem.accessibilityLabel = TraktCommunityCopy.rulesTitle
        navigationItem.leftBarButtonItems = [UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.close() }), rulesItem]
        let postTitle: String
        if case .edit = mode { postTitle = TraktCommunityCopy.save } else { postTitle = TraktCommunityCopy.post }
        postItem = UIBarButtonItem(primaryAction: UIAction(title: postTitle) { [weak self] _ in self?.post() })
        postItem.style = .done
        postItem.accessibilityIdentifier = "trakt.composer.post"
        if #available(iOS 26.0, *) { postItem.style = .prominent }
        navigationItem.rightBarButtonItem = postItem

        textView.font = Theme.Font.body
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Theme.Color.label
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: Theme.Space.s, left: Theme.Space.m - 5, bottom: Theme.Space.l, right: Theme.Space.m - 5)
        textView.keyboardDismissMode = .interactive
        textView.accessibilityIdentifier = "trakt.composer.text"
        textView.alwaysBounceVertical = true
        placeholder.font = Theme.Font.body
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = Theme.Color.labelTertiary
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false

        let context = contextView()
        let stack = UIStackView(arrangedSubviews: [context].compactMap { $0 })
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        if !TraktCommentRules.wereSeen() {
            let card = rulesView()
            rules = card
            stack.addArrangedSubview(card)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(textView)
        textView.addSubview(placeholder)

        buildBar()
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.s),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            textView.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: -Theme.Space.m + 5),
            textView.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: Theme.Space.m - 5),
            textView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: Theme.Space.s),
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor, constant: Theme.Space.m),
            placeholder.trailingAnchor.constraint(equalTo: textView.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.m),
        ])

        switch mode {
        case .new:
            title = TraktCommunityCopy.composeTitle
            placeholder.text = TraktCommunityCopy.placeholder
        case .reply:
            title = TraktCommunityCopy.replyTitle
            placeholder.text = TraktCommunityCopy.replyPlaceholder
        case .edit(let comment):
            title = TraktCommunityCopy.editTitle
            textView.text = comment.text
            spoilerButton.isSelected = comment.isSpoiler
        }
        if let draftKey, let draft = TraktCommentDrafts.load(draftKey) {
            textView.text = draft.text
            spoilerButton.isSelected = draft.isSpoiler
        }
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        textView.becomeFirstResponder()
    }

    /// What the comment is about: the title for a new one, the comment for a reply.
    private func contextView() -> UIView? {
        switch mode {
        case .new(_, let titleName):
            let icon = UIImageView(image: UIImage(systemName: "film", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)))
            icon.tintColor = Theme.Color.accent
            let label = UILabel()
            label.text = titleName
            label.font = Theme.Font.subheadlineSemibold
            label.textColor = Theme.Color.labelSecondary
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.spacing = 8
            row.alignment = .center
            return row
        case .reply(let parent):
            let avatar = TraktAvatarView(diameter: 28)
            avatar.configure(parent.user)
            let name = UILabel()
            name.text = TraktCommunityCopy.replyingTo(parent.user.displayName)
            name.font = Theme.Font.footnoteSemibold
            name.textColor = Theme.Color.labelSecondary
            name.adjustsFontForContentSizeCategory = true
            let quote = UILabel()
            let text = TraktCommentText(parent.text)
            quote.text = parent.isSpoiler ? TraktCommunityCopy.spoilerCover : text.textHidingSpoilers
            quote.font = Theme.Font.footnote
            quote.textColor = Theme.Color.labelSecondary
            quote.numberOfLines = 3
            quote.adjustsFontForContentSizeCategory = true
            let texts = UIStackView(arrangedSubviews: [name, quote])
            texts.axis = .vertical
            texts.spacing = 2
            let row = UIStackView(arrangedSubviews: [avatar, texts])
            row.spacing = 10
            row.alignment = .top
            let card = TraktCardBackground()
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            ])
            return card
        case .edit:
            return nil
        }
    }

    /// Trakt's rules, shown until the viewer has read them once.
    private func rulesView() -> UIView {
        let title = UILabel()
        title.text = TraktCommunityCopy.rulesTitle
        title.font = Theme.Font.subheadlineSemibold
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        let lines = TraktCommunityCopy.rules.map { rule -> UIView in
            let dot = UIImageView(image: UIImage(systemName: "checkmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)))
            dot.tintColor = Theme.Color.accent
            dot.setContentHuggingPriority(.required, for: .horizontal)
            let label = UILabel()
            label.text = rule
            label.font = Theme.Font.footnote
            label.textColor = Theme.Color.labelSecondary
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            let row = UIStackView(arrangedSubviews: [dot, label])
            row.spacing = 8
            row.alignment = .firstBaseline
            return row
        }
        var got = UIButton.Configuration.tinted()
        got.title = TraktCommunityCopy.gotIt
        got.cornerStyle = .capsule
        got.baseForegroundColor = Theme.Color.accentText
        got.baseBackgroundColor = Theme.Color.accent
        let button = UIButton(configuration: got, primaryAction: UIAction { [weak self] _ in self?.dismissRules() })
        button.accessibilityIdentifier = "trakt.composer.rules.ok"
        let stack = UIStackView(arrangedSubviews: [title] + lines + [button])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.setCustomSpacing(Theme.Space.s, after: lines.last ?? title)
        let card = TraktCardBackground()
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        card.accessibilityIdentifier = "trakt.composer.rules"
        return card
    }

    private func dismissRules() {
        TraktCommentRules.markSeen()
        guard let rules else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            rules.isHidden = true
            rules.alpha = 0
            self.view.layoutIfNeeded()
        }
    }

    /// The bar above the keyboard: the spoiler switch, Hide as Spoiler, Trakt's rules, and the word count with its ring.
    private func buildBar() {
        var spoiler = UIButton.Configuration.plain()
        spoiler.title = TraktCommunityCopy.spoiler
        spoiler.image = UIImage(systemName: "eye.slash")
        spoiler.imagePadding = 6
        spoiler.cornerStyle = .capsule
        spoiler.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        spoiler.titleLineBreakMode = .byTruncatingTail
        spoiler.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.footnoteSemibold
            return attributes
        }
        spoilerButton.configuration = spoiler
        spoilerButton.changesSelectionAsPrimaryAction = true
        spoilerButton.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.baseForegroundColor = button.isSelected ? .white : Theme.Color.label
            configuration?.background.backgroundColor = button.isSelected ? .systemRed : Theme.Color.surfaceRaised
            configuration?.image = UIImage(systemName: button.isSelected ? "eye.slash.fill" : "eye.slash")
            button.configuration = configuration
        }
        spoilerButton.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.refresh()
            self?.saveDraft()
        }, for: .primaryActionTriggered)
        spoilerButton.accessibilityLabel = TraktCommunityCopy.markSpoiler
        spoilerButton.accessibilityIdentifier = "trakt.composer.spoiler"

        var hide = UIButton.Configuration.plain()
        hide.image = UIImage(systemName: "rectangle.dashed")
        hide.title = TraktCommunityCopy.hidePart
        hide.titleLineBreakMode = .byTruncatingTail
        hide.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.footnoteSemibold
            return attributes
        }
        hide.imagePadding = 6
        hide.cornerStyle = .capsule
        hide.background.backgroundColor = Theme.Color.surfaceRaised
        hide.baseForegroundColor = Theme.Color.label
        hide.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        hideButton.configuration = hide
        hideButton.addAction(UIAction { [weak self] _ in self?.hideSelection() }, for: .primaryActionTriggered)
        hideButton.accessibilityIdentifier = "trakt.composer.hide"

        counter.font = Theme.Font.footnoteSemibold
        counter.textColor = Theme.Color.labelSecondary
        counter.adjustsFontForContentSizeCategory = true
        counter.textAlignment = .right
        counter.numberOfLines = 1
        counter.adjustsFontSizeToFitWidth = true
        counter.minimumScaleFactor = 0.8
        counter.accessibilityIdentifier = "trakt.composer.counter"
        counter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var translate = UIButton.Configuration.plain()
        translate.image = UIImage(systemName: "translate")
        translate.cornerStyle = .capsule
        translate.background.backgroundColor = Theme.Color.surfaceRaised
        translate.baseForegroundColor = Theme.Color.accentText
        translate.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        translateButton.configuration = translate
        translateButton.isHidden = true
        translateButton.accessibilityLabel = TranslationCopy.translateToEnglish
        translateButton.toolTip = TranslationCopy.translateToEnglish
        translateButton.accessibilityIdentifier = "trakt.composer.translate"
        translateButton.addAction(UIAction { [weak self] _ in self?.translateToEnglish() }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [spoilerButton, hideButton, translateButton, spacer, counter, ring])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        let glass = Glass.effectView(fallback: .systemChromeMaterial)
        glass.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(glass)
        bar.addSubview(row)
        let hairline = UIView()
        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hairline)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: bar.topAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: bar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, view.traitCollection.displayScale)),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
    }

    /// Trakt takes only English, so a draft written in another language can be put into English on the device, spoiler
    /// tags and all; the text is replaced the way typing would, so Undo brings the original back.
    private func translateToEnglish() {
        let text = textView.text ?? ""
        guard !isTranslating, !text.isEmpty else { return }
        isTranslating = true
        translateButton.configuration?.showsActivityIndicator = true
        translateButton.configuration?.image = nil
        Haptics.light()
        Task { [weak self] in
            let result: Result<String?, TranslationFailure>
            do throws(TranslationFailure) {
                result = .success(try await TranslationCenter.shared.translateDraft(text, into: "en"))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isTranslating = false
            self.translateButton.configuration?.showsActivityIndicator = false
            self.translateButton.configuration?.image = UIImage(systemName: "translate")
            switch result {
            case .success(let english?) where (self.textView.text ?? "") == text:
                if let all = self.textView.textRange(from: self.textView.beginningOfDocument, to: self.textView.endOfDocument) {
                    self.textView.replace(all, withText: english)
                }
                Haptics.success()
                TraktToast.show(TranslationCopy.translatedToEnglish, symbol: "translate", in: self.navigationController?.view ?? self.view, belowBar: true)
            case .success:
                self.refresh()
            case .failure(let failure):
                Haptics.error()
                if failure != .notInstalled { self.presentTraktMessage(TranslationCopy.failed) }
                self.refresh()
            }
        }
    }

    /// Offers Translate to English while the draft reads as another language and the device can translate it.
    private func refreshTranslateButton(_ text: String) {
        let foreign = TraktCommentDraft(text).wordCount >= 3 && TranslationCenter.shared.canTranslateDraft(text, into: "en")
        guard translateButton.isHidden == foreign || isTranslating else { return }
        translateButton.isHidden = !foreign && !isTranslating
    }

    private func showRules() {
        let alert = UIAlertController(title: TraktCommunityCopy.rulesTitle, message: TraktCommunityCopy.rules.map { "• " + $0 }.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: TraktCommunityCopy.gotIt, style: .default))
        present(alert, animated: true)
    }

    private func hideSelection() {
        Haptics.light()
        let wrapped = TraktCommentDraft.wrappingSpoiler(textView.text ?? "", range: textView.selectedRange)
        textView.text = wrapped.text
        textView.selectedRange = wrapped.cursor
        refresh()
        saveDraft()
    }

    func textViewDidChange(_ textView: UITextView) {
        refresh()
        saveDraft()
    }

    private func saveDraft() {
        guard let draftKey, !isPosting else { return }
        TraktCommentDrafts.save(.init(text: textView.text ?? "", isSpoiler: spoilerButton.isSelected), for: draftKey)
    }

    private func refresh() {
        let draft = TraktCommentDraft(textView.text ?? "")
        placeholder.isHidden = !(textView.text ?? "").isEmpty
        let changed: Bool
        if case .edit(let comment) = mode {
            changed = draft.text != original || spoilerButton.isSelected != comment.isSpoiler
        } else {
            changed = true
        }
        postItem.isEnabled = draft.canPost && changed && !isPosting
        if case .new = mode {
            title = draft.isReview ? TraktCommunityCopy.composeReviewTitle : TraktCommunityCopy.composeTitle
        }
        if let concern = TraktCommunityCopy.concern(draft) {
            counter.text = concern
            counter.textColor = draft.wordCount < TraktCommentDraft.minimumWords ? Theme.Color.labelSecondary : .systemOrange
        } else if draft.isReview {
            counter.text = "\(TraktCommunityCopy.review) · \(TraktCommunityCopy.wordCount(draft.wordCount))"
            counter.textColor = .systemTeal
        } else {
            counter.text = draft.wordCount == 0 ? nil : TraktCommunityCopy.wordCount(draft.wordCount)
            counter.textColor = Theme.Color.labelSecondary
        }
        ring.set(progress: draft.reviewProgress, ready: draft.canPost, review: draft.isReview)
        refreshTranslateButton(draft.text)
    }

    private func post() {
        let draft = TraktCommentDraft(textView.text ?? "")
        guard draft.canPost, !isPosting else { return }
        isPosting = true
        refresh()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = false }
        textView.isEditable = false
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoiler = spoilerButton.isSelected
        let mode = mode
        Task { [weak self] in
            do {
                let confirmation: String
                switch mode {
                case .new(let subject, _):
                    _ = try await TraktCommunity.shared.post(text, spoiler: spoiler, on: subject)
                    confirmation = TraktCommunityCopy.posted
                case .reply(let parent):
                    _ = try await TraktCommunity.shared.reply(text, spoiler: spoiler, to: parent)
                    confirmation = TraktCommunityCopy.replied
                case .edit(let comment):
                    _ = try await TraktCommunity.shared.edit(comment, text: text, spoiler: spoiler)
                    confirmation = TraktCommunityCopy.saved
                }
                Haptics.success()
                guard let self else { return }
                let presenter = self.navigationController?.presentingViewController
                self.dismiss(animated: true) {
                    guard let presenter else { return }
                    let host = (presenter as? UINavigationController)?.topViewController ?? presenter
                    TraktToast.show(confirmation, symbol: "checkmark", in: host.navigationController?.view ?? host.view, belowBar: host.navigationController != nil)
                }
            } catch {
                Haptics.error()
                guard let self else { return }
                self.isPosting = false
                self.navigationItem.rightBarButtonItem = self.postItem
                self.navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = true }
                self.textView.isEditable = true
                self.refresh()
                self.presentTraktMessage(error.localizedDescription)
            }
        }
    }

    private var hasUnsavedText: Bool {
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if case .edit(let comment) = mode {
            return text != original.trimmingCharacters(in: .whitespacesAndNewlines) || spoilerButton.isSelected != comment.isSpoiler
        }
        return !text.isEmpty
    }

    private func close() {
        guard hasUnsavedText, !isPosting else { return dismiss(animated: true) }
        let sheet = UIAlertController(title: TraktCommunityCopy.discardTitle, message: nil, preferredStyle: .actionSheet)
        if draftKey != nil {
            sheet.addAction(UIAlertAction(title: TraktCommunityCopy.keepDraft, style: .default) { [weak self] _ in
                self?.saveDraft()
                self?.dismiss(animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: TraktCommunityCopy.discard, style: .destructive) { [weak self] _ in
            if let key = self?.draftKey { TraktCommentDrafts.clear(key) }
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        close()
    }
}

/// A small ring that fills toward a review's 200 words: grey until the comment can be posted, accent once it can, teal once it
/// is a review.
final class TraktWordRing: UIView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22)])
        for shape in [track, fill] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 3
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = Theme.Color.surfaceHigh.cgColor
        fill.strokeEnd = 0
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 2, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        track.path = path.cgPath
        fill.path = path.cgPath
        track.strokeColor = Theme.Color.surfaceHigh.resolvedColor(with: traitCollection).cgColor
    }

    func set(progress: Double, ready: Bool, review: Bool) {
        fill.strokeColor = (review ? UIColor.systemTeal : (ready ? Theme.Color.accent : Theme.Color.labelTertiary)).resolvedColor(with: traitCollection).cgColor
        fill.strokeEnd = max(0.02, CGFloat(progress))
    }
}
