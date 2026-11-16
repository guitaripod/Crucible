import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// Writes a comment, a review or a reply (`TVCommentComposerViewController`): the text in an editor that wraps and grows,
/// under it the word count toward Trakt's five words and toward a review at 200 or what Trakt would object to, then Mark
/// as Spoiler and Post (or Save), and Trakt's rules until the viewer has read them. Drafts are kept per title and per
/// reply; Ctrl+Return posts.
@MainActor
final class CommentComposerScreen: ScreenView {
    enum Mode {
        case new(TraktCommunitySubject, titleName: String)
        case reply(TraktComment)
        case edit(TraktComment)
    }

    private enum RowID {
        static let spoiler = "composer.spoiler"
        static let post = "composer.post"
    }

    private let mode: Mode
    private var isSpoiler: Bool
    private var isPosting = false
    private let page = PageView()
    private let heading: ScreenTitleView
    private let editor = TextEditorView(placeholder: TraktCommunityCopy.placeholder)
    private let status = ComposerNote()
    private let rows = RowListView()
    private let rules = ComposerNote()
    /// Trakt's rules show in the composer the viewer first opens, and not again.
    private let showsRules = !TraktCommentRules.wereSeen()
    private lazy var body = ComposerColumn(views: [editor, status, rows, rules])

    init(mode: Mode) {
        self.mode = mode
        var text = ""
        switch mode {
        case .edit(let comment):
            text = comment.text
            isSpoiler = comment.isSpoiler
            heading = ScreenTitleView(title: TraktCommunityCopy.editTitle)
        case .reply(let parent):
            let draft = TraktCommentDrafts.load(TraktCommunity.draftKey(replyingTo: parent.id))
            text = draft?.text ?? ""
            isSpoiler = draft?.isSpoiler ?? false
            heading = ScreenTitleView(title: TraktCommunityCopy.replyTitle, detail: TraktCommunityCopy.replyingTo(parent.user.displayName))
        case .new(let subject, let titleName):
            let draft = TraktCommentDrafts.load(TraktCommunity.draftKey(subject: subject))
            text = draft?.text ?? ""
            isSpoiler = draft?.isSpoiler ?? false
            heading = ScreenTitleView(title: TraktCommunityCopy.composeTitle, detail: titleName)
        }
        super.init()
        addSubview(page)
        page.setSections([heading, body])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        editor.setText(text, notify: false)
        editor.onChange = { [weak self] _ in
            self?.saveDraft()
            self?.render()
        }
        editor.onSubmit = { [weak self] in self?.post() }
        rows.onSelect = { [weak self] item in self?.select(item.id) }
        render()
    }

    override var preferredFocusView: View? { editor }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        TraktCommentRules.markSeen()
    }

    private var draftKey: String? {
        switch mode {
        case .new(let subject, _): return TraktCommunity.draftKey(subject: subject)
        case .reply(let parent): return TraktCommunity.draftKey(replyingTo: parent.id)
        case .edit: return nil
        }
    }

    private var isEditingComment: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func render() {
        let draft = TraktCommentDraft(editor.text)
        if let concern = TraktCommunityCopy.concern(draft) {
            status.show(concern, tone: .warning)
        } else if draft.wordCount > 0 {
            let count = TraktCommunityCopy.wordCount(draft.wordCount)
            status.show(draft.isReview ? "\(TraktCommunityCopy.review) · \(count)" : count, tone: .neutral)
        } else {
            status.show(nil, tone: .neutral)
        }
        let rulesText = TraktCommunityCopy.rulesTitle + "\n" + TraktCommunityCopy.rules.map { "· " + $0 }.joined(separator: "\n")
        rules.show(showsRules ? rulesText : nil, tone: .neutral)
        rows.setItems([
            RowItem.onOff(id: RowID.spoiler, title: TraktCommunityCopy.markSpoiler, isOn: isSpoiler, symbol: isSpoiler ? "eye.slash.fill" : "eye.slash"),
            RowItem(id: RowID.post, title: isEditingComment ? TraktCommunityCopy.save : TraktCommunityCopy.post, symbol: "paperplane.fill",
                    isEnabled: draft.canPost && !isPosting),
        ])
        body.setNeedsLayout()
        page.setNeedsLayout()
    }

    private func select(_ id: String) {
        switch id {
        case RowID.spoiler:
            isSpoiler.toggle()
            saveDraft()
            render()
        case RowID.post:
            post()
        default:
            break
        }
    }

    private func saveDraft() {
        guard let draftKey else { return }
        TraktCommentDrafts.save(.init(text: editor.text, isSpoiler: isSpoiler), for: draftKey)
    }

    private func post() {
        let draft = TraktCommentDraft(editor.text)
        guard draft.canPost, !isPosting else { return }
        isPosting = true
        render()
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoiler = isSpoiler
        let mode = mode
        Task { [weak self] in
            do {
                switch mode {
                case .new(let subject, _): _ = try await TraktCommunity.shared.post(text, spoiler: spoiler, on: subject)
                case .reply(let parent): _ = try await TraktCommunity.shared.reply(text, spoiler: spoiler, to: parent)
                case .edit(let comment): _ = try await TraktCommunity.shared.edit(comment, text: text, spoiler: spoiler)
                }
                _ = self?.navigation?.pop()
            } catch {
                guard let self else { return }
                self.isPosting = false
                self.render()
                CommunityActions.alert(TraktCopy.name, message: error.localizedDescription, from: self)
            }
        }
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        page.setNeedsLayout()
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The composer's views stacked in the settings column's width.
@MainActor
private final class ComposerColumn: View {
    private let views: [View]

    init(views: [View]) {
        self.views = views
        super.init()
        views.forEach(addSubview)
    }

    private var column: (x: Float, width: Float) {
        let metrics = Theme.current.metrics
        let width = min(metrics.wideColumn, frame.width - metrics.sideMargin * 2)
        return (((frame.width - width) / 2).rounded(), width)
    }

    private var spacing: Float { Theme.current.metrics.tv(28) }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let width = min(metrics.wideColumn, size.width - metrics.sideMargin * 2)
        let heights = views.map { $0.sizeThatFits(Size(width: width, height: 0)).height }.filter { $0 > 0 }
        return Size(width: size.width, height: heights.reduce(0, +) + Float(max(heights.count - 1, 0)) * spacing + metrics.tv(60))
    }

    override func layoutSubviews() {
        let (x, width) = column
        var y: Float = 0
        for view in views {
            let height = view.sizeThatFits(Size(width: width, height: 0)).height
            let rowsBleed = view is RowListView ? Theme.current.metrics.sideMargin : 0
            view.frame = Rect(x: x - rowsBleed, y: y, width: width + rowsBleed * 2, height: height)
            if let rows = view as? RowListView { rows.columnWidth = width }
            if height > 0 { y += height + spacing }
        }
    }
}

/// A line of text under the editor: the word count, what Trakt would object to (in the warning colour), or the rules.
@MainActor
private final class ComposerNote: View {
    enum Tone { case neutral, warning }

    private var text: String?
    private var tone = Tone.neutral

    func show(_ newText: String?, tone newTone: Tone) {
        guard newText != text || newTone != tone else { return }
        text = newText
        tone = newTone
        superview?.setNeedsLayout()
        setNeedsDisplay()
    }

    private func layout(width: Float) -> TextLayout? {
        guard let text, !text.isEmpty else { return nil }
        return TextLayout(text, font: Theme.current.type.cardSubtitle, maxWidth: width, maxLines: 0, scale: window?.scale ?? 1)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: layout(width: size.width)?.size.height ?? 0)
    }

    override func draw(_ context: inout DrawContext) {
        guard let layout = layout(width: frame.width) else { return }
        let palette = Theme.current.palette
        context.text(layout, at: .zero, color: tone == .warning ? Color(srgbRed: 1, green: 0.62, blue: 0.04) : palette.labelSecondary)
    }
}
