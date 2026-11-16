import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Asking What to Watch (`TVWhatToWatchAskViewController`): what is sent and where, a field for a sentence of one's own
/// (Return suggests), and the example requests one click away. The picks open over this screen, so Back comes here to ask
/// for something else.
@MainActor
final class WhatToWatchAskScreen: ScreenView {
    private let api: APIClient
    private let page = PageView()
    private let column: AskColumn

    init(api: APIClient) {
        self.api = api
        column = AskColumn(takesOwnWords: HostedBrain.takesAnyRequest)
        super.init()
        addSubview(page)
        page.setSections([ScreenTitleView(title: WatchCopy.title), column])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        column.onAsk = { [weak self] request in self?.ask(request) }
    }

    override var preferredFocusView: View? { column }
    override var remembersFocus: Bool { true }

    private func ask(_ request: String) {
        guard !WatchPicker.cleaned(request).isEmpty else { return }
        navigation?.push(WhatToWatchScreen(api: api, request: request))
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

/// The ask screen's column: the explanation, the field with Suggest, and the examples.
@MainActor
private final class AskColumn: View {
    var onAsk: ((String) -> Void)?
    private let field = TextFieldView(placeholder: WatchCopy.placeholder, symbol: "wand.and.stars")
    private let suggest = ButtonView(style: .primary, title: WatchCopy.suggest)
    private let examples: [ButtonView]
    private let takesOwnWords: Bool

    init(takesOwnWords: Bool) {
        self.takesOwnWords = takesOwnWords
        examples = WatchCopy.examples.map { ButtonView(style: .glass, title: $0) }
        super.init()
        if takesOwnWords {
            [field, suggest].forEach(addSubview)
            field.onSubmit = { [weak self] text in self?.onAsk?(text) }
            suggest.onPress = { [weak self] in
                guard let self else { return }
                self.onAsk?(self.field.text)
            }
        }
        for (index, button) in examples.enumerated() {
            button.onPress = { [weak self] in self?.onAsk?(WatchCopy.examples[index]) }
            addSubview(button)
        }
    }

    override var preferredFocusView: View? { takesOwnWords ? field : examples.first }
    override var remembersFocus: Bool { true }

    private var metrics: Metrics { Theme.current.metrics }
    private var explanation: String { HostedBrain.takesAnyRequest ? OwnModelCopy.askExplanation : WatchCopy.explanation }

    private func column(_ width: Float) -> (x: Float, width: Float) {
        (metrics.sideMargin, min(metrics.wideColumn, width - metrics.sideMargin * 2))
    }

    private func explanationLayout(width: Float) -> TextLayout {
        TextLayout(explanation, font: Theme.current.type.body, maxWidth: width, maxLines: 0, scale: window?.scale ?? 1)
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let (_, width) = column(size.width)
        let control = metrics.primaryControlHeight
        var height = explanationLayout(width: width).size.height + metrics.tv(48)
        if takesOwnWords { height += control + metrics.tv(40) }
        height += Float(examples.count) * (control + metrics.tv(20))
        return Size(width: size.width, height: height + metrics.tv(60))
    }

    override func layoutSubviews() {
        let (x, width) = column(frame.width)
        let control = metrics.primaryControlHeight
        var y = explanationLayout(width: width).size.height + metrics.tv(48)
        if takesOwnWords {
            let suggestWidth = suggest.sizeThatFits(Size(width: width, height: control)).width
            field.frame = Rect(x: x, y: y, width: width - suggestWidth - metrics.tv(20), height: control)
            suggest.frame = Rect(x: x + width - suggestWidth, y: y, width: suggestWidth, height: control)
            y += control + metrics.tv(40)
        }
        for button in examples {
            let size = button.sizeThatFits(Size(width: width, height: control))
            button.frame = Rect(x: x, y: y, width: min(size.width, width), height: control)
            y += control + metrics.tv(20)
        }
    }

    override func draw(_ context: inout DrawContext) {
        let (x, width) = column(frame.width)
        context.text(explanationLayout(width: width), at: Point(x: x, y: 0), color: Theme.current.palette.labelSecondary)
    }
}

/// The picks for one request (`TVWhatToWatchViewController`): two columns of tiles, each with its reason, under the request.
/// It asks once when it opens, showing each step meanwhile; coming back from a pick's page shows the same picks again.
@MainActor
final class WhatToWatchScreen: ScreenView {
    private let api: APIClient
    private let request: String
    private let session: WatchSession
    private let page = PageView()
    private let heading: ScreenTitleView
    private let grid = PickGrid()
    private let state = StateView()
    private var answer: WatchAnswer?
    private var askTask: Task<Void, Never>?

    init(api: APIClient, request: String) {
        self.api = api
        self.request = WatchPicker.cleaned(request)
        session = WatchSession(api: api)
        heading = ScreenTitleView(title: WatchCopy.title, detail: self.request)
        super.init()
        [page, state].forEach(addSubview)
        page.setSections([heading, grid])
        page.onScroll = { [weak self] offset in self?.rootView?.contentScrolled(offset: offset) }
        grid.onOpen = { [weak self] pick in self?.open(pick) }
        ask()
    }

    override var preferredFocusView: View? { state.isHidden ? grid : state }
    override var remembersFocus: Bool { true }

    private func ask() {
        show(.loading(title: WatchCopy.step(.readingLibrary)))
        let session = session
        let request = request
        askTask?.cancel()
        let (steps, stepsIn) = AsyncStream<WatchStep>.makeStream()
        askTask = Task { [weak self] in
            let follow = Task { [weak self] in
                for await step in steps { self?.showStep(step) }
            }
            let result = await session.answer(request) { stepsIn.yield($0) }
            stepsIn.finish()
            await follow.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let answer): self.display(answer)
            case .failure(let failure): self.display(failure)
            }
        }
    }

    /// The line beside the spinner says what is happening, while the screen still waits.
    private func showStep(_ step: WatchStep) {
        guard answer == nil, !state.isHidden else { return }
        state.show(.loading(title: WatchCopy.step(step)))
    }

    private func display(_ answer: WatchAnswer) {
        self.answer = answer
        DemoTour.shared.record(.whatToWatch)
        heading.detail = answer.note.isEmpty ? request : request + "\n" + answer.note
        grid.show(answer)
        let hadFocus = containsFocus
        state.isHidden = true
        page.isHidden = false
        page.fadeIn()
        if hadFocus { window?.focus.focus(grid, animated: false) }
        setNeedsLayout()
    }

    private func display(_ failure: WatchFailure) {
        MidgarLog.notice("What to Watch showed a failure: \(failure)", category: .lifecycle)
        let back = StateView.Action(title: String(localized: "Back")) { [weak self] in _ = self?.navigation?.pop() }
        guard WatchCopy.canRetry(failure) else {
            show(.empty(title: WatchCopy.title, message: OwnModelCopy.failure(failure), symbol: "wand.and.stars", action: back))
            return
        }
        show(.error(title: WatchCopy.title, message: OwnModelCopy.failure(failure), retryTitle: WatchCopy.tryAgain,
                    retry: { [weak self] in self?.ask() }, secondary: back))
    }

    private func show(_ newState: StateView.State) {
        let hadFocus = containsFocus
        state.show(newState)
        state.isHidden = false
        page.isHidden = true
        if hadFocus || window?.focusedView == nil { window?.focus.focus(state, animated: false) }
    }

    private func open(_ pick: WatchPick) {
        let route: DetailRoute
        switch pick.title.kind {
        case .movie: route = .item(ratingKey: pick.id, mediaType: "movie", showRatingKey: nil, seasonRatingKey: nil)
        case .show: route = .show(ratingKey: pick.id, initialSeasonKey: nil)
        }
        navigation?.push(DetailScreen.make(api: api, route: route, placeholder: answer?.item(for: pick)))
    }

    override func screenWillDisappear() {
        guard answer == nil else { return }
        askTask?.cancel()
    }

    override func layoutSubviews() {
        page.topInset = Theme.current.metrics.tabBarClearance
        page.frame = bounds
        page.setNeedsLayout()
        state.frame = bounds
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The picks in two columns, each a focusable tile.
@MainActor
private final class PickGrid: View {
    var onOpen: ((WatchPick) -> Void)?
    private var tiles: [StatsPanelView] = []

    func show(_ answer: WatchAnswer) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = answer.picks.map { pick in
            let tile = StatsPanelView(content: PickTileContent(pick: pick, posterPath: answer.item(for: pick)?.thumb), flush: true)
            tile.onSelect = { [weak self] in self?.onOpen?(pick) }
            addSubview(tile)
            return tile
        }
        superview?.setNeedsLayout()
        setNeedsLayout()
    }

    override var preferredFocusView: View? { tiles.first }
    override var remembersFocus: Bool { true }

    private var metrics: Metrics { Theme.current.metrics }
    private var tileHeight: Float { metrics.tv(330) }

    override func sizeThatFits(_ size: Size) -> Size {
        let rows = (tiles.count + 1) / 2
        return Size(width: size.width, height: Float(rows) * (tileHeight + metrics.gutter) + metrics.tv(60))
    }

    override func layoutSubviews() {
        let margin = metrics.sideMargin
        let width = ((frame.width - margin * 2 - metrics.gutter) / 2).rounded(.down)
        for (index, tile) in tiles.enumerated() {
            let column = Float(index % 2)
            let row = Float(index / 2)
            tile.frame = Rect(x: margin + column * (width + metrics.gutter), y: metrics.tv(20) + row * (tileHeight + metrics.gutter), width: width, height: tileHeight)
        }
    }
}

/// One pick (`TVWatchPickSurface`): the poster beside the title, what the library knows of it, and the model's sentence on
/// why it fits.
@MainActor
private final class PickTileContent: View {
    private let pick: WatchPick
    private let poster: ArtworkView

    init(pick: WatchPick, posterPath: String?) {
        self.pick = pick
        poster = ArtworkView(source: posterPath.map { .path($0, .poster) })
        super.init()
        poster.cornerRadius = Theme.current.metrics.radiusS
        addSubview(poster)
    }

    override var isPointerInteractive: Bool { false }
    override var accessibilityLabel: String? { [pick.title.title, WatchCopy.facts(pick.title), pick.why].filter { !$0.isEmpty }.joined(separator: ", ") }

    private var metrics: Metrics { Theme.current.metrics }
    private var posterSize: Size { Size(width: metrics.tv(180), height: metrics.tv(270)) }

    override func layoutSubviews() {
        poster.frame = Rect(x: metrics.tv(32), y: ((frame.height - posterSize.height) / 2).rounded(), width: posterSize.width, height: posterSize.height)
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let type = Theme.current.type
        let palette = Theme.current.palette
        let x = metrics.tv(32) + posterSize.width + metrics.tv(40)
        let width = frame.width - x - metrics.tv(40)
        let title = TextLayout(pick.title.title, font: type.title3, maxWidth: width, maxLines: 2, scale: scale)
        let facts = TextLayout(WatchCopy.facts(pick.title), font: type.subheadline, maxWidth: width, scale: scale)
        let why = TextLayout(pick.why, font: type.body, maxWidth: width, maxLines: 4, scale: scale)
        let total = title.size.height + metrics.tv(4) + facts.size.height + metrics.tv(16) + why.size.height
        var y = ((frame.height - total) / 2).rounded()
        context.text(title, at: Point(x: x, y: y), color: palette.label)
        y += title.size.height + metrics.tv(4)
        context.text(facts, at: Point(x: x, y: y), color: palette.labelSecondary)
        y += facts.size.height + metrics.tv(16)
        context.text(why, at: Point(x: x, y: y), color: palette.label)
    }
}
