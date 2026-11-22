import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln

/// The sheet beside a Short with what its publisher wrote under it and the top of its comments, which yt-dlp reads in a
/// second, slower run. It scrolls under the wheel, and under the arrows while the keyboard or a gamepad is on it.
@MainActor
final class WebShortsDetailsPanel: View {
    enum Comments {
        case loading
        case loaded([WebComment])
        case failed(String)
    }

    var onClose: (() -> Void)?

    private let page = PageView()
    private let close = ButtonView(style: .plain, title: nil, symbol: "xmark")
    private let heading = PaddedLabel(font: Theme.current.type.headline, maxLines: 3)
    private let facts = PaddedLabel(font: Theme.current.type.footnote, maxLines: 2, isSecondary: true)
    private let summary = PaddedLabel(font: Theme.current.type.body, maxLines: 60)
    private let commentsTitle = PaddedLabel(font: Theme.current.type.caption1, maxLines: 1, isSecondary: true)
    private let status = StatusLineView()
    private lazy var statusSection = InsetSection(status, top: Theme.current.metrics.tv(14))
    private var blocks: [WebShortCommentView] = []

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        close.spokenTitle = String(localized: "Close")
        close.onPress = { [weak self] in self?.onClose?() }
        commentsTitle.text = WebShortsCopy.comments.uppercased()
        commentsTitle.topSpacing = Theme.current.metrics.tv(36)
        summary.topSpacing = Theme.current.metrics.tv(22)
        facts.topSpacing = Theme.current.metrics.tv(10)
        status.isCentered = false
        [page, close].forEach(addSubview)
        page.showsIndicator = true
    }

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var cursor: Cursor { .default }
    override var accessibilityLabel: String? { WebShortsCopy.details }

    /// Shows `entry`'s title and facts, and what yt-dlp said of it once it has.
    func show(_ entry: WebEntry, video: WebVideo?) {
        heading.text = entry.title
        var line: [String] = []
        if let channel = entry.channel { line.append(channel) }
        if let likes = video?.likeCount, likes > 0 { line.append(WebShortsCopy.likes(likes)) }
        if let known = WebFormatting.facts(entry) { line.append(known) }
        facts.text = line.joined(separator: " · ")
        summary.text = video?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        rebuild()
    }

    func show(_ comments: Comments) {
        blocks = []
        switch comments {
        case .loading:
            status.show(String(localized: "Loading comments…", comment: "A web video's page while its comments are read"), busy: true)
        case .failed(let message):
            status.show(message, tone: .error)
        case .loaded(let loaded):
            status.show(loaded.isEmpty ? String(localized: "No comments.", comment: "A web video's page without comments") : nil)
            blocks = loaded.map(WebShortCommentView.init)
        }
        rebuild()
    }

    /// Back to the top, as for another clip.
    func rewind() {
        page.setOffset(0, animated: false)
    }

    private func rebuild() {
        var sections: [View] = [heading]
        if !facts.text.isEmpty { sections.append(facts) }
        if !summary.text.isEmpty { sections.append(summary) }
        sections += [commentsTitle, statusSection]
        sections += blocks
        page.setSections(sections)
        page.setNeedsLayout()
        setNeedsDisplay()
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        let step = Theme.current.metrics.tv(220)
        switch event.key {
        case .up: page.setOffset(page.offset - step, animated: true)
        case .down: page.setOffset(page.offset + step, animated: true)
        case .pageUp: page.setOffset(page.offset - page.frame.height * 0.85, animated: true)
        case .pageDown: page.setOffset(page.offset + page.frame.height * 0.85, animated: true)
        case .home: page.setOffset(0, animated: true)
        case .end: page.setOffset(page.maximumOffset, animated: true)
        case .left, .escape, .back: onClose?()
        default: return false
        }
        return true
    }

    override func pointerPressed(_ button: MouseButton, at point: Point) -> Bool { true }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let side = metrics.plainControlHeight
        close.frame = Rect(x: bounds.width - side - metrics.tv(16), y: metrics.tv(16), width: side, height: side)
        page.topInset = metrics.tv(34)
        page.bottomInset = metrics.tv(40)
        page.frame = bounds
        heading.trailingSpacing = side + metrics.tv(8)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let dark = Theme.current.palette.appearance == .dark
        GlassStyle.frostedSheet(in: bounds, radius: Theme.current.metrics.radiusL, scale: scale, dark: dark, veil: 0.82, context: &context)
    }

    override func drawOverlay(_ context: inout DrawContext) {
        guard isFocused, window?.isFocusVisible == true, let scale = window?.scale else { return }
        context.stroke(bounds, radius: Theme.current.metrics.radiusL, width: max(2, 3 / scale), color: Theme.current.palette.accent)
    }
}

/// A run of text in the details sheet, kept in from the sheet's edges.
@MainActor
private final class PaddedLabel: View {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            superview?.setNeedsLayout()
        }
    }
    var topSpacing: Float = 0
    var trailingSpacing: Float = 0 { didSet { if trailingSpacing != oldValue { superview?.setNeedsLayout() } } }
    private let label: Label

    init(font: Font, maxLines: Int, isSecondary: Bool = false) {
        label = Label("", font: font, color: isSecondary ? Theme.current.palette.labelSecondary : Theme.current.palette.label, maxLines: maxLines)
        super.init()
        addSubview(label)
    }

    private var inset: Float { Theme.current.metrics.tv(36) }

    override func sizeThatFits(_ size: Size) -> Size {
        guard !text.isEmpty else { return Size(width: size.width, height: 0) }
        let fitted = label.sizeThatFits(Size(width: max(size.width - inset * 2 - trailingSpacing, 1), height: size.height))
        return Size(width: size.width, height: fitted.height + topSpacing)
    }

    override func layoutSubviews() {
        label.frame = Rect(x: inset, y: topSpacing, width: max(bounds.width - inset * 2 - trailingSpacing, 1), height: max(bounds.height - topSpacing, 0))
    }
}

/// A view of the details sheet kept in from the sheet's edges, as tall as the view wants to be.
@MainActor
private final class InsetSection: View {
    private let content: View
    private let top: Float

    init(_ content: View, top: Float) {
        self.content = content
        self.top = top
        super.init()
        addSubview(content)
    }

    private var inset: Float { Theme.current.metrics.tv(36) }

    override func sizeThatFits(_ size: Size) -> Size {
        let fitted = content.sizeThatFits(Size(width: max(size.width - inset * 2, 1), height: size.height))
        return Size(width: size.width, height: fitted.height > 0 ? fitted.height + top : 0)
    }

    override func layoutSubviews() {
        content.frame = Rect(x: inset, y: top, width: max(bounds.width - inset * 2, 1), height: max(bounds.height - top, 0))
    }
}

/// One comment: who wrote it, how long ago and how many liked it, then what it says.
@MainActor
final class WebShortCommentView: View {
    private let comment: WebComment
    private let picture = ArtworkView()

    init(_ comment: WebComment) {
        self.comment = comment
        super.init()
        picture.source = WebArtwork.source(comment.authorThumbnail)
        addSubview(picture)
    }

    override var accessibilityLabel: String? { "\(comment.author): \(comment.text)" }

    private var inset: Float { Theme.current.metrics.tv(36) }
    private var diameter: Float { Theme.current.metrics.tv(52) }
    private var textX: Float { inset + diameter + Theme.current.metrics.tv(18) }

    private var byline: String {
        var parts = [comment.author]
        if let published = comment.published, let age = Formatters.unixRelativeDate(Int(published.timeIntervalSince1970)) { parts.append(age) }
        if let likes = comment.likeCount, likes > 0 { parts.append("♥ " + Formatters.compactCount(likes)) }
        return parts.joined(separator: " · ")
    }

    private func layouts(width: Float, scale: Float) -> (byline: TextLayout, text: TextLayout) {
        let type = Theme.current.type
        let column = max(width - textX - inset, 1)
        return (TextLayout(byline, font: type.footnote, maxWidth: column, maxLines: 1, scale: scale),
                TextLayout(comment.text, font: type.body, maxWidth: column, maxLines: 14, scale: scale))
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let metrics = Theme.current.metrics
        let laidOut = layouts(width: size.width, scale: window?.scale ?? 1)
        let height = laidOut.byline.size.height + metrics.tv(6) + laidOut.text.size.height
        return Size(width: size.width, height: max(height, diameter) + metrics.tv(34))
    }

    override func layoutSubviews() {
        picture.frame = Rect(x: inset, y: Theme.current.metrics.tv(20), width: diameter, height: diameter)
        picture.cornerRadius = diameter / 2
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let laidOut = layouts(width: bounds.width, scale: scale)
        let top = metrics.tv(20)
        let marked = comment.isPinned || comment.isByUploader
        context.text(laidOut.byline, at: Point(x: textX, y: top), color: marked ? theme.palette.accentText : theme.palette.labelSecondary)
        context.text(laidOut.text, at: Point(x: textX, y: top + laidOut.byline.size.height + metrics.tv(6)), color: theme.palette.label)
    }
}
