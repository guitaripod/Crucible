import CrucibleCore
import CrucibleStats
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The Year in Review poster's preview (`WrappedSharePreviewViewController`): Story or Square, the poster as it will be
/// saved, and Save to Pictures and Copy Image where the phone has its share sheet. Ctrl+S saves and Ctrl+C copies. The
/// export draws the same view offscreen at the poster's full 1080 pixel width.
@MainActor
final class YearPosterScreen: ScreenView {
    private let page: StatsPage
    private let source: StatsSource
    private let heading: ScreenTitleView
    private let formatButtons: [(format: YearPosterFormat, button: ButtonView)]
    private let saveButton = ButtonView(style: .primary, title: String(localized: "Save to Pictures"), symbol: "square.and.arrow.down")
    private let copyButton = ButtonView(style: .glass, title: String(localized: "Copy Image"), symbol: "doc.on.doc")
    private let status = StatusLineView()
    private var poster: YearPosterView?
    private var content: YearPosterContent?
    private var format = YearPosterFormat.story
    private var appearance = Animated(1)
    private var loadTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var isExporting = false

    init(page: StatsPage, source: StatsSource) {
        self.page = page
        self.source = source
        heading = ScreenTitleView(title: StatsShareFacts(page: page, time: StatsTime()).shareTitle)
        formatButtons = YearPosterFormat.allCases.map { ($0, ButtonView(style: .chip(selected: $0 == .story), title: $0.title)) }
        super.init()
        status.isCentered = true
        [heading, status, saveButton, copyButton].forEach(addSubview)
        for (candidate, button) in formatButtons {
            addSubview(button)
            button.onPress = { [weak self] in self?.select(candidate) }
        }
        saveButton.onPress = { [weak self] in self?.export(.save) }
        copyButton.onPress = { [weak self] in self?.export(.copy) }
        status.show(String(localized: "Loading…"), busy: true)
    }

    override var preferredFocusView: View? { saveButton }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        guard content == nil, loadTask == nil, let window else { return }
        let page = page
        let source = source
        loadTask = Task { [weak self] in
            let loaded = await YearPosterContent.load(page: page, source: source, window: window)
            guard let self, !Task.isCancelled else { return }
            self.show(loaded)
        }
    }

    override func screenWillDisappear() {
        confirmationTask?.cancel()
    }

    private func show(_ loaded: YearPosterContent) {
        content = loaded
        let view = YearPosterView(content: loaded, format: format)
        insertSubview(view, at: 0)
        poster = view
        status.show(nil)
        appearance.reset(0)
        appearance.set(1, animation: .fade)
        view.alpha = 0
        startAnimating()
        setNeedsLayout()
    }

    private func select(_ next: YearPosterFormat) {
        guard next != format else { return }
        format = next
        for (candidate, button) in formatButtons { button.style = .chip(selected: candidate == next) }
        poster?.format = next
        appearance.reset(0.35)
        appearance.set(1, animation: .fade)
        startAnimating()
        setNeedsLayout()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = appearance.advance(dt)
        poster?.alpha = appearance.value
        return moving
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.contains(.control), event.modifiers.isDisjoint(with: [.alt, .super, .shift]), !event.isRepeat else { return false }
        if event.clipboardCommand == .copy {
            export(.copy)
            return true
        }
        guard Unicode.Scalar(event.key.rawValue).map({ Character($0).lowercased() }) == "s" else { return false }
        export(.save)
        return true
    }

    // MARK: Export

    private enum Export {
        case save, copy
    }

    /// Draws the poster at full size and saves it to Pictures or puts it on the clipboard, confirming on the button.
    private func export(_ kind: Export) {
        guard let content, let window, !isExporting else { return }
        isExporting = true
        let format = format
        let title = heading.title
        guard let capture = YearPosterScreen.render(content, format: format, gpu: window.gpu) else {
            isExporting = false
            status.show(String(localized: "Couldn't Make the Card"), tone: .error)
            return
        }
        Task { [weak self] in
            let png = await Task.detached { PNGWriter.encode(linear: capture.pixels, width: capture.width, height: capture.height) }.value
            guard let self else { return }
            defer { self.isExporting = false }
            guard let png else {
                MidgarLog.error("The Year in Review poster did not encode as PNG", category: .stats)
                self.status.show(String(localized: "Couldn't Make the Card"), tone: .error)
                return
            }
            switch kind {
            case .copy:
                window.copy(png, mimeType: "image/png")
                self.status.show(nil)
                self.confirm(self.copyButton, title: String(localized: "Copied"), restoring: String(localized: "Copy Image"), symbol: "doc.on.doc")
            case .save:
                await self.save(png, name: "\(title) (\(format.title))")
            }
        }
    }

    private func save(_ png: Data, name: String) async {
        let result = await Task.detached { () -> Result<URL, Error> in
            Result { try PicturesFolder.write(png, named: name) }
        }.value
        switch result {
        case .success(let url):
            MidgarLog.notice("Saved the Year in Review poster to \(url.path)", category: .stats)
            status.show(PicturesFolder.displayPath(url))
            confirm(saveButton, title: String(localized: "Saved"), restoring: String(localized: "Save to Pictures"), symbol: "square.and.arrow.down")
        case .failure(let error):
            MidgarLog.error("The Year in Review poster could not be saved: \(error.localizedDescription)", category: .stats)
            status.show(String(localized: "Couldn’t Save the Image"), tone: .error)
        }
    }

    /// Shows `title` with a check on `button` for a moment, then puts the button back.
    private func confirm(_ button: ButtonView, title: String, restoring original: String, symbol: Symbol) {
        confirmationTask?.cancel()
        for other in [saveButton, copyButton] where other !== button {
            other.title = other === saveButton ? String(localized: "Save to Pictures") : String(localized: "Copy Image")
            other.symbol = other === saveButton ? "square.and.arrow.down" : "doc.on.doc"
        }
        button.title = title
        button.symbol = "checkmark"
        confirmationTask = Task { [weak self, weak button] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let button else { return }
            button.title = original
            button.symbol = symbol
            self?.setNeedsLayout()
        }
        setNeedsLayout()
    }

    /// The poster drawn offscreen at its full size on the app's GPU, as linear light; nil when no window could be made.
    static func render(_ content: YearPosterContent, format: YearPosterFormat, gpu: GPU) -> (width: Int, height: Int, pixels: [Float])? {
        let view = YearPosterView(content: content, format: format)
        guard let offscreen = try? Window(offscreen: format.size, scale: 1, gpu: gpu, contentView: view) else { return nil }
        offscreen.render()
        return offscreen.capture()
    }

    // MARK: Layout

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let margin = metrics.sideMargin
        let headingHeight = heading.sizeThatFits(Size(width: bounds.width, height: 0)).height
        heading.frame = Rect(x: 0, y: metrics.tabBarClearance, width: bounds.width, height: headingHeight)
        let rowTop = heading.frame.maxY + metrics.tv(12)
        let spacing = metrics.tv(16)
        let chips = formatButtons.map { ($0.button, $0.button.sizeThatFits(.zero)) }
        let actions = [copyButton, saveButton].map { ($0, $0.sizeThatFits(.zero)) }
        let rowHeight = (chips + actions).map(\.1.height).max() ?? 0
        let chipsWidth = chips.reduce(0) { $0 + $1.1.width } + spacing * Float(chips.count - 1)
        let actionsWidth = actions.reduce(0) { $0 + $1.1.width } + spacing * Float(actions.count - 1)
        let fitsOnOneRow = margin + chipsWidth + metrics.tv(24) + actionsWidth <= bounds.width - margin
        place(chips, from: margin, top: rowTop, rowHeight: rowHeight, spacing: spacing)
        place(actions, from: fitsOnOneRow ? bounds.width - margin - actionsWidth : margin, top: fitsOnOneRow ? rowTop : rowTop + rowHeight + spacing,
              rowHeight: rowHeight, spacing: spacing)
        let controlsBottom = saveButton.frame.maxY
        let oneLine = TextLayout("Ag", font: Theme.current.type.callout, scale: window?.scale ?? 1).size.height
        let statusHeight = max(status.sizeThatFits(Size(width: bounds.width - margin * 2, height: 0)).height, oneLine, metrics.tv(36))
        let bottomRoom = metrics.tv(40)
        status.frame = Rect(x: margin, y: bounds.height - bottomRoom - statusHeight, width: bounds.width - margin * 2, height: statusHeight)
        let stageTop = controlsBottom + metrics.tv(36)
        let stage = Rect(x: margin, y: stageTop, width: bounds.width - margin * 2, height: max(0, status.frame.minY - metrics.tv(20) - stageTop))
        guard let poster else {
            status.frame.y = (stage.midY - statusHeight / 2).rounded()
            return
        }
        let aspect = format.size.width / format.size.height
        var size = Size(width: stage.width, height: stage.width / aspect)
        if size.height > stage.height { size = Size(width: stage.height * aspect, height: stage.height) }
        poster.frame = Rect(x: (stage.midX - size.width / 2).rounded(), y: (stage.midY - size.height / 2).rounded(), width: size.width.rounded(),
                            height: size.height.rounded())
    }

    /// Lays `buttons` out left to right from `x`, each centred on a row of `rowHeight`.
    private func place(_ buttons: [(ButtonView, Size)], from x: Float, top: Float, rowHeight: Float, spacing: Float) {
        var left = x
        for (button, size) in buttons {
            button.frame = Rect(x: left, y: top + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            left += size.width + spacing
        }
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
        guard let poster, !poster.isHidden else { return }
        let metrics = Theme.current.metrics
        context.faded(poster.alpha) { faded in
            faded.shadow(poster.frame, radius: 0, blur: metrics.tv(40), offsetY: metrics.tv(16), opacity: 0.5)
        }
    }
}
