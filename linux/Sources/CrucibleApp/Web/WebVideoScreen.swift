import CrucibleCore
import CrucibleUI
import CrucibleWeb
import Foundation
import Kiln
import MidgarCore

/// A web video's page: its thumbnail, title and facts with what can be done with it, its description, its chapters and
/// the top of its comments. The card shows at once; yt-dlp fills in the description and chapters, and the comments,
/// which take it longer, arrive after.
@MainActor
final class WebVideoScreen: ScreenView, Reloadable {
    private var entry: WebEntry
    private var video: WebVideo?
    private var comments: [WebComment]?
    private let page = PageView()
    private let header = WebVideoHeader()
    private let actions = ChipRowView()
    private let about = RowListView()
    private let chaptersTitle = SectionTitleView(title: ChapterList.title)
    private let chapters = RowListView()
    private let commentsTitle = SectionTitleView(title: String(localized: "Comments", comment: "Section of a web video's page"))
    private let commentsState = StatusLineView()
    private let commentRows = RowListView()
    private var videoTask: Task<Void, Never>?
    private var commentsTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(entry: WebEntry) {
        self.entry = entry
        super.init()
        addSubview(page)
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        actions.onSelect = { [weak self] chip in self?.choose(chip.id) }
        about.onSelect = { [weak self] _ in self?.openDescription() }
        chapters.onSelect = { [weak self] item in
            guard let self, let index = Int(item.id.dropFirst("chapter.".count)), let chapter = self.video?.chapters[safe: index] else { return }
            WebActions.play(self.entry, at: chapter.start, from: self)
        }
        commentRows.onSelect = { [weak self] item in
            guard let self, let comment = self.comments?.first(where: { $0.id == item.id }) else { return }
            self.rootView?.push(ReaderScreen(title: comment.author, markup: Self.markup(comment.text)))
        }
        for name in [WebLibrary.didChange, WebDownloads.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            })
        }
        render()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        videoTask?.cancel()
        commentsTask?.cancel()
    }

    override var preferredFocusView: View? { actions }

    override func screenDidAppear() {
        if video == nil { load(fresh: false) }
        render()
    }

    override func screenWillDisappear() {
        videoTask?.cancel()
        commentsTask?.cancel()
    }

    func reload() {
        load(fresh: true)
    }

    private func load(fresh: Bool) {
        let address = entry.url
        videoTask?.cancel()
        videoTask = Task { [weak self] in
            guard let loaded = try? await WebService.shared.video(address, fresh: fresh) else { return }
            guard let self, !Task.isCancelled else { return }
            self.video = loaded
            self.entry = WebEntry(loaded)
            self.render()
        }
        commentsTask?.cancel()
        commentsState.show(String(localized: "Loading comments…", comment: "A web video's page while its comments are read"), busy: true)
        commentsTask = Task { [weak self] in
            let outcome: Result<[WebComment], any Error>
            do {
                outcome = .success(try await WebService.shared.videoWithComments(address).comments.filter { $0.parentID == nil })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let loaded):
                self.comments = loaded
                self.commentsState.show(loaded.isEmpty ? String(localized: "No comments.", comment: "A web video's page without comments") : nil)
            case .failure(let error):
                self.commentsState.show(WebService.message(for: error), tone: .error)
            }
            self.render()
        }
    }

    private func render() {
        let library = WebService.shared.library
        header.artwork = WebArtwork.source(for: entry)
        header.title = entry.title
        header.channel = [entry.channel, video?.channelFollowers.map { count in
            String(localized: "\(Formatters.compactCount(count)) subscribers", comment: "How many follow a channel on its site, as in \"25.8M subscribers\"")
        }].compactMap { $0 }.joined(separator: " · ")
        header.facts = [WebFormatting.facts(entry), entry.duration.flatMap { $0 > 0 ? Formatters.timestamp($0) : nil }].compactMap { $0 }.joined(separator: " · ")
        let resumes = library.resumePosition(of: entry.id) > 0
        var chips: [ChipRowView.Chip] = [.init(id: "play", title: resumes ? String(localized: "Resume") : String(localized: "Play"), symbol: "play.fill", isSelected: true)]
        if resumes { chips.append(.init(id: "restart", title: String(localized: "Play from Beginning"), symbol: "gobackward")) }
        let saved = library.isSavedForLater(entry.id)
        chips.append(.init(id: "later", title: saved ? String(localized: "Remove from Watch Later", comment: "Web video menu") : WebCopy.watchLater,
                           symbol: saved ? "minus.circle" : "clock"))
        if let channelID = entry.channelID {
            let follows = library.isSubscribed(to: channelID)
            chips.append(.init(id: "follow", title: follows ? String(localized: "Following", comment: "Button on a followed channel's page; pressing it unfollows")
                                                           : String(localized: "Follow", comment: "Button that follows a channel"),
                               symbol: follows ? "checkmark" : "plus"))
        }
        if entry.channelURL != nil || entry.channelID != nil {
            chips.append(.init(id: "channel", title: String(localized: "Go to Channel", comment: "Web video menu"), symbol: "person.crop.circle"))
        }
        if WebDownloads.shared.isRunning(entry.id) {
            chips.append(.init(id: "download.cancel", title: WebDownloads.downloadingTitle, symbol: "xmark.circle"))
        } else if library.download(of: entry.id) != nil {
            chips.append(.init(id: "download.delete", title: WebDownloads.deleteTitle, symbol: "trash"))
        } else if !entry.isLive, !entry.isUpcoming {
            chips.append(.init(id: "download", title: WebDownloads.downloadTitle, symbol: "arrow.down.circle"))
        }
        actions.setChips(chips)
        var sections: [View] = [header, actions]
        if let summary = video?.summary, !summary.isEmpty {
            about.setItems([RowItem(id: "description", title: String(localized: "Description", comment: "A web video's description, as its publisher wrote it"),
                                    subtitle: summary.replacingOccurrences(of: "\n", with: " "), symbol: "text.alignleft", accessory: .chevron)])
            sections.append(about)
        }
        if let listed = video?.chapters, listed.count > 1 {
            chapters.setItems(listed.enumerated().map { index, chapter in
                RowItem(id: "chapter.\(index)", title: chapter.title, value: TransportView.clock(chapter.start), symbol: "play.fill")
            })
            sections += [chaptersTitle, chapters]
        }
        sections += [commentsTitle, commentsState]
        if let comments, !comments.isEmpty {
            commentRows.setItems(comments.map { comment in
                var line = [comment.author]
                if let published = comment.published, let age = Formatters.unixRelativeDate(Int(published.timeIntervalSince1970)) { line.append(age) }
                if let likes = comment.likeCount, likes > 0 { line.append("♥ " + Formatters.compactCount(likes)) }
                return RowItem(id: comment.id, title: line.joined(separator: " · "), subtitle: comment.text.replacingOccurrences(of: "\n", with: " "),
                               symbol: comment.isPinned ? "star.fill" : (comment.isByUploader ? "checkmark.seal" : "bubble.left"), accessory: .chevron)
            })
            sections.append(commentRows)
        }
        page.setSections(sections)
        page.setNeedsLayout()
    }

    private func choose(_ id: String) {
        let library = WebService.shared.library
        switch id {
        case "play": WebActions.play(entry, from: self)
        case "restart": WebActions.play(entry, at: 0, from: self)
        case "later":
            if library.isSavedForLater(entry.id) { library.removeFromWatchLater(entry.id) } else { library.saveForLater(entry) }
        case "follow":
            guard let channelID = entry.channelID else { return }
            if library.isSubscribed(to: channelID) {
                library.unsubscribe(from: channelID)
            } else {
                library.subscribe(to: WebChannel(id: channelID, title: entry.channel ?? channelID, url: entry.channelURL))
            }
        case "channel": WebActions.openChannel(of: entry, from: self)
        case "download": WebDownloads.shared.start(entry, in: window)
        case "download.cancel": WebDownloads.shared.cancel(entry.id)
        case "download.delete": WebDownloads.shared.delete(entry.id)
        default: break
        }
    }

    private func openDescription() {
        guard let summary = video?.summary else { return }
        rootView?.push(ReaderScreen(title: entry.title, markup: Self.markup(summary)))
    }

    /// Plain text as the reader's markup, in which `&`, `<` and `>` would otherwise read as formatting.
    private static func markup(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The head of a web video's page: its thumbnail with its title, channel and facts beside it.
@MainActor
final class WebVideoHeader: View {
    var title = "" { didSet { setNeedsDisplay() } }
    var channel = "" { didSet { setNeedsDisplay() } }
    var facts = "" { didSet { setNeedsDisplay() } }
    var artwork: ArtworkSource? { didSet { picture.source = artwork } }

    private let picture = ArtworkView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        picture.cornerRadius = Theme.current.metrics.radiusM
        addSubview(picture)
    }

    private var pictureSize: Size {
        let height = Theme.current.metrics.tv(270)
        return Size(width: (height * 16 / 9).rounded(), height: height)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: pictureSize.height + Theme.current.metrics.tv(30))
    }

    override func layoutSubviews() {
        picture.frame = Rect(x: Theme.current.metrics.sideMargin, y: 0, width: pictureSize.width, height: pictureSize.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        let metrics = theme.metrics
        let x = picture.frame.maxX + metrics.tv(40)
        let width = max(frame.width - x - metrics.sideMargin, 0)
        var y = metrics.tv(8)
        let name = TextLayout(title, font: theme.type.title3, maxWidth: width, maxLines: 3, scale: scale)
        context.text(name, at: Point(x: x, y: y), color: theme.palette.label)
        y += name.size.height + metrics.tv(12)
        for line in [channel, facts] where !line.isEmpty {
            let layout = TextLayout(line, font: theme.type.callout, maxWidth: width, maxLines: 1, scale: scale)
            context.text(layout, at: Point(x: x, y: y), color: theme.palette.labelSecondary)
            y += layout.size.height + metrics.tv(6)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
