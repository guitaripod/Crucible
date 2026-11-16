import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// Diagnostics (`TVDiagnosticsViewController`): the newest lines of Crucible's log in a viewer you scroll by focusing it,
/// with the log's counts, the image cache size and the version beside it, Refresh Log and Clear Image Cache.
@MainActor
final class DiagnosticsScreen: ScreenView {
    private let heading = ScreenTitleView(title: String(localized: "Diagnostics"),
                                          detail: String(localized: "The newest lines of Crucible’s log. Focus the log and use the arrow keys or the wheel to read older entries."))
    private let stats = StatsPanel()
    private let refresh = ButtonView(style: .glass, title: String(localized: "Refresh Log"), symbol: "arrow.clockwise")
    private let clear = ButtonView(style: .glass, title: String(localized: "Clear Image Cache"), symbol: "trash")
    private let log = LogView()
    private var loadTask: Task<Void, Never>?

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        [heading, stats, refresh, clear, log].forEach(addSubview)
        refresh.onPress = { [weak self] in self?.reload() }
        clear.onPress = { [weak self] in self?.confirmClearCache() }
    }

    override var preferredFocusView: View? { log }
    override var remembersFocus: Bool { true }

    override func screenDidAppear() {
        reload()
    }

    override func screenWillDisappear() {
        loadTask?.cancel()
    }

    private func reload() {
        loadTask?.cancel()
        let cacheDirectory = LinuxSession.imageCacheDirectory
        loadTask = Task { [weak self] in
            async let tail = LogTail.read()
            async let cacheBytes = Task.detached(priority: .utility) { Self.measure(cacheDirectory) }.value
            let (newTail, bytes) = await (tail, cacheBytes)
            guard let self, !Task.isCancelled else { return }
            self.show(newTail, cacheBytes: bytes)
        }
    }

    private func show(_ tail: LogTail, cacheBytes: Int64) {
        let lines = tail.lines.count < tail.totalLineCount
            ? String(localized: "\(tail.lines.count) of \(tail.totalLineCount)")
            : "\(tail.totalLineCount)"
        stats.rows = [
            (String(localized: "Log lines"), lines),
            (String(localized: "Errors"), String(tail.errorCount)),
            (String(localized: "Log size"), ByteCountFormatter.string(fromByteCount: Int64(tail.byteCount), countStyle: .file)),
            (String(localized: "Image cache"), ImageCacheMeter.formatted(cacheBytes)),
            (String(localized: "Version"), AppInfo.versionSummary),
            (String(localized: "Log file"), Self.compact(Self.homeRelative(CrucibleLog.directory.appendingPathComponent(CrucibleLog.fileName).path))),
        ]
        log.lines = tail.isEmpty ? [String(localized: "The log is empty.")] : tail.lines
        setNeedsLayout()
    }

    /// `path` cut short in the middle so its folder and file name show in the panel's narrow value column: the start, an
    /// ellipsis, then the last two components (`~/…/logs/crucible.log`).
    private static func compact(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 4 else { return path }
        return ([parts[0], "…"] + parts.suffix(2)).joined(separator: "/")
    }

    /// `path` with the home directory written as `~`.
    private static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The bytes the image cache takes on disk.
    private nonisolated static func measure(_ root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func confirmClearCache() {
        guard let window else { return }
        AlertView.confirm(title: String(localized: "Clear Image Cache?"),
                          message: String(localized: "Artwork downloads again as you browse."),
                          confirm: String(localized: "Clear"), in: window) { [weak self] in
            try? FileManager.default.removeItem(at: LinuxSession.imageCacheDirectory)
            self?.window?.purgeImageMemory()
            self?.reload()
        }
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        let left = metrics.tv(620)
        let gap = metrics.tv(60)
        let top = metrics.tabBarClearance
        let headingHeight = heading.sizeThatFits(Size(width: left + metrics.sideMargin * 2, height: 0)).height
        heading.frame = Rect(x: 0, y: top, width: left + metrics.sideMargin * 2, height: headingHeight)
        let statsHeight = stats.sizeThatFits(Size(width: left, height: 0)).height
        stats.frame = Rect(x: metrics.sideMargin, y: heading.frame.maxY + metrics.tv(24), width: left, height: statsHeight)
        var y = stats.frame.maxY + metrics.tv(32)
        for button in [refresh, clear] {
            let size = button.sizeThatFits(Size(width: left, height: metrics.primaryControlHeight))
            button.frame = Rect(x: metrics.sideMargin, y: y, width: size.width, height: size.height)
            y += size.height + metrics.tv(20)
        }
        let logX = metrics.sideMargin + left + gap
        log.frame = Rect(x: logX, y: top, width: max(frame.width - logX - metrics.sideMargin, metrics.tv(400)), height: frame.height - top - metrics.tv(60))
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
    }
}

/// The log's counts as label and value rows on a raised panel.
@MainActor
private final class StatsPanel: ReadOnlyPanelView {
    var rows: [(String, String)] = [] { didSet { superview?.setNeedsLayout(); setNeedsDisplay() } }

    override var accessibilityLabel: String? { rows.map { "\($0.0) \($0.1)" }.joined(separator: ", ") }

    private var rowHeight: Float { Theme.current.metrics.tv(46) }
    private var inset: Float { Theme.current.metrics.tv(28) }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: inset * 2 + rowHeight * Float(max(rows.count, 1)))
    }

    override func draw(_ context: inout DrawContext) {
        guard let scale = window?.scale else { return }
        let theme = Theme.current
        context.fill(bounds, radius: theme.metrics.radiusL, color: theme.palette.surface)
        for (index, row) in rows.enumerated() {
            let y = inset + Float(index) * rowHeight
            let label = TextLayout(row.0, font: theme.type.callout, maxWidth: bounds.width * 0.45, scale: scale)
            var font = theme.type.callout
            font.monospacedDigits = true
            let value = TextLayout(row.1, font: font, maxWidth: bounds.width * 0.55 - inset * 2, scale: scale)
            context.text(label, at: Point(x: inset, y: y), color: theme.palette.labelSecondary)
            context.text(value, at: Point(x: bounds.width - inset - value.size.width, y: y), color: theme.palette.label)
        }
    }
}

/// The log's lines, newest at the bottom, in a panel the focus can sit on. Up and Down (and the wheel) read a page further;
/// only at the end of the log does an arrow move the focus on.
@MainActor
private final class LogView: View {
    var lines: [String] = [] {
        didSet {
            layouts = []
            offset = .greatestFiniteMagnitude
            setNeedsDisplay()
        }
    }

    private var layouts: [TextLayout] = []
    private var layoutWidth: Float = 0
    private var offset: Float = 0
    private var lit = Animated(0)

    override var canBecomeFocused: Bool { true }
    override var isPointerInteractive: Bool { true }
    override var accessibilityRole: AccessibilityRole { .paragraph }
    override var accessibilityLabel: String? { lines.suffix(12).joined(separator: "\n") }

    private var inset: Float { Theme.current.metrics.tv(28) }

    private func makeLayouts() {
        guard let scale = window?.scale else { return }
        let width = bounds.width - inset * 2
        guard layouts.isEmpty || layoutWidth != width else { return }
        layoutWidth = width
        var font = Theme.current.type.footnote
        font.monospacedDigits = true
        layouts = lines.map { TextLayout($0, font: font, maxWidth: width, maxLines: 4, scale: scale) }
    }

    private var contentHeight: Float {
        layouts.reduce(Float(0)) { $0 + $1.size.height + Theme.current.metrics.tv(6) }
    }

    private var maximumOffset: Float { max(0, contentHeight - (bounds.height - inset * 2)) }

    /// Moves a page; false at the end, so the focus may leave.
    private func page(_ direction: Float) -> Bool {
        makeLayouts()
        let target = min(max(offset + direction * (bounds.height - inset * 2) * 0.85, 0), maximumOffset)
        guard target != offset else { return false }
        offset = target
        setNeedsDisplay()
        return true
    }

    override func keyPressed(_ event: KeyEvent) -> Bool {
        guard event.modifiers.isEmpty else { return false }
        switch event.key {
        case .up, .pageUp: return page(-1)
        case .down, .pageDown: return page(1)
        case .home:
            offset = 0
            setNeedsDisplay()
            return true
        case .end:
            offset = maximumOffset
            setNeedsDisplay()
            return true
        default: return false
        }
    }

    override func scrolled(_ event: ScrollEvent) -> Bool {
        makeLayouts()
        let step = event.isDiscrete ? event.notchesY * Theme.current.metrics.tv(120) : event.dy
        offset = min(max(offset + step, 0), maximumOffset)
        setNeedsDisplay()
        return true
    }

    override func focusDidChange(focused: Bool, animated: Bool) {
        lit.set(focused ? 1 : 0, animation: .focus)
        startAnimating()
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = lit.advance(dt)
        setNeedsDisplay()
        return moving
    }

    override func draw(_ context: inout DrawContext) {
        makeLayouts()
        offset = min(offset, maximumOffset)
        let theme = Theme.current
        let palette = theme.palette
        context.fill(bounds, radius: theme.metrics.radiusL, color: palette.surface)
        if lit.value > 0.01 {
            context.fill(bounds.insetBy(-2, -2), radius: theme.metrics.radiusL + 2, color: palette.focusFill.withAlpha(0.18 * lit.value))
            context.fill(bounds, radius: theme.metrics.radiusL, color: palette.surface)
        }
        var y = inset - offset
        let visible = Rect(x: 0, y: inset, width: bounds.width, height: bounds.height - inset * 2)
        for (index, layout) in layouts.enumerated() {
            let height = layout.size.height
            defer { y += height + theme.metrics.tv(6) }
            guard y + height > visible.minY, y < visible.maxY else { continue }
            let isError = LogTail.isError(lines[index])
            context.text(layout, at: Point(x: inset, y: y), color: isError ? palette.destructive : palette.labelSecondary)
        }
    }
}
