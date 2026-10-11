import CrucibleCore
import CrucibleDesign
import UIKit

/// Diagnostics: the newest lines of the app log in a monospaced viewer you scroll by focusing it and
/// swiping, with the log's counts and the image cache size beside it.
final class TVDiagnosticsViewController: UIViewController {
    private let logView = TVLogTextView()
    private let linesValue = UILabel()
    private let errorsValue = UILabel()
    private let sizeValue = UILabel()
    private let cacheValue = UILabel()
    private lazy var refreshButton = TVButton.make(.glass, title: "Refresh Log", symbol: "arrow.clockwise") { [weak self] in self?.reload() }
    private lazy var clearButton = TVButton.make(.glass, title: "Clear Image Cache", symbol: "trash") { [weak self] in self?.confirmClearCache() }
    private var loadTask: Task<Void, Never>?
    private var hasShownLog = false

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Diagnostics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [logView] }

    /// A click Up or Down while the log is focused reads one page further in that direction; only
    /// at the end of the log does the click move the focus on.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.previouslyFocusedItem === logView else { return true }
        switch context.focusHeading {
        case .up: return !logView.scrollPage(towardsStart: true)
        case .down: return !logView.scrollPage(towardsStart: false)
        default: return true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        buildHierarchy()
        refreshButton.accessibilityIdentifier = "diagnostics.refresh"
        clearButton.accessibilityIdentifier = "diagnostics.clearCache"
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func buildHierarchy() {
        let heading = TVSettingsHeadingView(title: "Diagnostics", body: "The newest lines of Crucible's log. Focus the log and swipe to read older entries.")

        let statRows = UIStackView(arrangedSubviews: [
            statRow("Log lines", linesValue),
            statRow("Errors", errorsValue),
            statRow("Log size", sizeValue),
            statRow("Image cache", cacheValue),
        ])
        statRows.axis = .vertical
        statRows.spacing = Theme.Space.xs
        let stats = TVReadOnlyPanel(wrapping: statRows) { [weak self] in self?.spokenCounts }
        stats.accessibilityIdentifier = "diagnostics.counts"
        let headingPanel = TVReadOnlyPanel(wrapping: heading) { [weak heading] in heading?.spokenText }

        let buttons = UIStackView(arrangedSubviews: [refreshButton, clearButton])
        buttons.axis = .vertical
        buttons.alignment = .leading
        buttons.spacing = Theme.Space.s

        let left = UIStackView(arrangedSubviews: [headingPanel, stats, buttons])
        left.axis = .vertical
        left.spacing = Theme.Space.l
        left.alignment = .fill
        left.translatesAutoresizingMaskIntoConstraints = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(left)
        view.addSubview(logView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: TVSettingsScaffold.Layout.contextWidth),
            left.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            logView.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: TVSettingsScaffold.Layout.columnGap),
            logView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            logView.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            logView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -TVSettingsScaffold.Layout.contentBottom),
        ])
    }

    private var spokenCounts: String {
        [("Log lines", linesValue), ("Errors", errorsValue), ("Log size", sizeValue), ("Image cache", cacheValue)]
            .map { "\($0.0) \($0.1.text ?? "")" }
            .joined(separator: ", ")
    }

    private func statRow(_ title: String, _ value: UILabel) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.Font.callout
        label.textColor = Theme.Color.labelSecondary
        value.font = Theme.Font.callout
        value.textColor = Theme.Color.label
        value.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [label, UIView(), value])
        row.alignment = .firstBaseline
        return row
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            async let tail = LogTail.read()
            async let cacheBytes = ImageCacheMeter.totalBytes()
            let (newTail, newBytes) = await (tail, cacheBytes)
            guard !Task.isCancelled, let self else { return }
            show(newTail, cacheBytes: newBytes)
        }
    }

    private func show(_ tail: LogTail, cacheBytes: Int64) {
        linesValue.text = tail.lines.count < tail.totalLineCount
            ? "\(tail.lines.count) of \(tail.totalLineCount)"
            : "\(tail.totalLineCount)"
        errorsValue.text = "\(tail.errorCount)"
        sizeValue.text = ByteCountFormatter.string(fromByteCount: Int64(tail.byteCount), countStyle: .file)
        cacheValue.text = ImageCacheMeter.formatted(cacheBytes)
        logView.show(tail)
        focusLogOnFirstLoad()
    }

    /// The log is only eligible for focus once it has content to scroll, so the first load hands
    /// the focus over to it; later reloads leave the focus on whatever the user is using.
    private func focusLogOnFirstLoad() {
        guard !hasShownLog else { return }
        hasShownLog = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func confirmClearCache() {
        let alert = UIAlertController(
            title: "Clear Image Cache?",
            message: "Posters and backdrops will be downloaded again as you browse.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            Task { [weak self] in
                await ImageLoader.shared.clearCache()
                self?.reload()
            }
        })
        present(alert, animated: true)
    }
}

/// A read-only, scrollable log. tvOS scrolls a focused scroll view with the remote's touch surface,
/// so the log itself takes the focus; the plate brightens and gets an ember rim while focused.
final class TVLogTextView: UIScrollView {
    private static let emptyText = "No log entries yet."

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let inset = Theme.Space.m
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: inset),
            label.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -inset),
            label.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor, constant: -inset),
            contentLayoutGuide.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "diagnostics.log"
        accessibilityLabel = "Log"
        applyAppearance(focused: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVLogTextView, _: UITraitCollection) in
            view.applyAppearance(focused: view.isFocused)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { true }

    /// Scrolls one page (a little less than the visible height, so a line of context stays) and
    /// returns false when the log is already at that end.
    func scrollPage(towardsStart: Bool) -> Bool {
        let minimum: CGFloat = 0
        let maximum = max(0, contentSize.height - bounds.height)
        let page = bounds.height * 0.85
        let target = towardsStart ? max(minimum, contentOffset.y - page) : min(maximum, contentOffset.y + page)
        guard abs(target - contentOffset.y) > 0.5 else { return false }
        setContentOffset(CGPoint(x: 0, y: target), animated: !UIAccessibility.isReduceMotionEnabled)
        return true
    }

    func show(_ tail: LogTail) {
        let font = UIFont.monospacedSystemFont(ofSize: 23, weight: .regular)
        guard !tail.isEmpty else {
            label.attributedText = NSAttributedString(string: Self.emptyText, attributes: [.font: font, .foregroundColor: Theme.Color.labelSecondary])
            accessibilityValue = Self.emptyText
            return
        }
        let text = NSMutableAttributedString()
        for (index, line) in tail.lines.enumerated() {
            let isError = LogTail.isError(line)
            text.append(NSAttributedString(
                string: index == 0 ? line : "\n" + line,
                attributes: [.font: font, .foregroundColor: isError ? Theme.Color.destructive : Theme.Color.label]
            ))
        }
        label.attributedText = text
        accessibilityValue = tail.lines.joined(separator: "\n")
        layoutIfNeeded()
        setContentOffset(CGPoint(x: 0, y: max(0, contentSize.height - bounds.height)), animated: false)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({ self.applyAppearance(focused: focused) })
    }

    private func applyAppearance(focused: Bool) {
        backgroundColor = focused ? Theme.Color.surfaceHigh : Theme.Color.surface
        layer.borderColor = (focused ? Theme.Color.accent : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
    }
}
