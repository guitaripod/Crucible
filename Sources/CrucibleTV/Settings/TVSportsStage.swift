import CrucibleCore
import CrucibleDesign
import UIKit

/// What the context column of Sports Research shows for the focused row: an eyebrow, a heading, a poster with a file name
/// becoming its title, a paragraph, and a few lines with symbols.
struct TVSportsStageContent {
    struct Art {
        var file: String
        var title: String
        var words: SportsPosterWords?
        var posterPath: String?
    }

    struct Line {
        var symbol: String
        var tint: UIColor
        var title: String
        var detail: String?
        var emphasized = false
    }

    var eyebrow: String?
    var eyebrowTint: UIColor = Theme.Color.accentText
    var heading: String?
    var art: Art?
    var body: String?
    var lines: [Line] = []
    /// While research runs: when its timer reads zero, so the eyebrow counts the seconds between reports.
    var runningSince: Date?
}

/// The context column of Sports Research: the screen's title over a stage that changes with the focus. A new subject
/// cross-dissolves in and plays its file name becoming its title; the same subject updates in place, so the live research
/// ticks without flashing.
final class TVSportsStage: TVReadOnlyPanel {
    private static let posterWidth: CGFloat = 180

    private let titleView = TVScreenTitleView(clearsTabBar: false, column: TVSettingsScaffold.Layout.contextWidth)
    private let eyebrowLabel = UILabel()
    private let headingLabel = UILabel()
    private let poster = SportsPosterView()
    private let change = SportsTransformView()
    private let artRow = UIStackView()
    private let bodyLabel = UILabel()
    private let linesStack = UIStackView()
    private let stack = UIStackView()
    private var content = TVSportsStageContent()
    private var key: String?
    private var eyebrowBase: String?
    private var timer: Timer?

    init(title: String) {
        super.init(frame: .zero)
        titleView.configure(TVScreenTitleContent(title: title))
        eyebrowLabel.font = TVFont.eyebrow
        eyebrowLabel.numberOfLines = 1
        headingLabel.font = Theme.Font.scaled(.title3, 40, .bold, maximum: 52)
        headingLabel.textColor = Theme.Color.label
        headingLabel.numberOfLines = 3
        bodyLabel.font = TVFont.cardSubtitle
        bodyLabel.textColor = Theme.Color.labelSecondary
        bodyLabel.numberOfLines = 6
        linesStack.axis = .vertical
        linesStack.spacing = Theme.Space.s
        linesStack.clipsToBounds = true
        linesStack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        titleView.setContentCompressionResistancePriority(.required, for: .vertical)
        poster.translatesAutoresizingMaskIntoConstraints = false
        artRow.addArrangedSubview(poster)
        artRow.addArrangedSubview(change)
        artRow.axis = .horizontal
        artRow.alignment = .center
        artRow.spacing = Theme.Space.l
        [titleView, eyebrowLabel, headingLabel, artRow, bodyLabel, linesStack].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.xs, after: eyebrowLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            poster.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 1.5),
        ])
        spokenLabel = { [weak self] in self?.spokenText }
        accessibilityIdentifier = "settings.context"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lines that the column cannot fit whole are left out rather than cut through the middle.
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layoutIfNeeded()
        fitLines()
    }

    private func fitLines() {
        let room = linesStack.bounds.height + 1
        for line in linesStack.arrangedSubviews {
            line.alpha = line.frame.maxY <= room ? 1 : 0
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartTimer()
    }

    /// Shows `content` for the subject `key`: cross-dissolving and playing the change when the subject is new, in place
    /// when it is the one already showing.
    func show(_ content: TVSportsStageContent, key: String) {
        let isNew = key != self.key
        self.content = content
        self.key = key
        guard isNew, window != nil else {
            apply()
            return
        }
        TVMotion.dissolve(stack, duration: TVMetrics.Duration.heroText) { self.apply() }
        if content.art != nil, !UIAccessibility.isReduceMotionEnabled { change.play() }
    }

    private func apply() {
        eyebrowBase = content.eyebrow?.uppercased(with: .current)
        eyebrowLabel.textColor = content.eyebrowTint
        Self.setShown(eyebrowLabel, eyebrowBase != nil)
        updateEyebrow()
        headingLabel.text = content.heading
        Self.setShown(headingLabel, content.heading != nil)
        if let art = content.art {
            poster.show(path: art.posterPath, width: Self.posterWidth, words: art.words)
            change.show(file: art.file, title: art.title, titleFont: Theme.Font.scaled(.title3, 38, .bold, maximum: 50), fileFont: TVFont.mono(size: 21))
        }
        Self.setShown(artRow, content.art != nil)
        bodyLabel.text = content.body
        Self.setShown(bodyLabel, !(content.body?.isEmpty ?? true))
        linesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.lines.map(Self.lineView).forEach(linesStack.addArrangedSubview)
        Self.setShown(linesStack, !content.lines.isEmpty)
        stack.setNeedsLayout()
        stack.layoutIfNeeded()
        fitLines()
        restartTimer()
    }

    /// Shows or hides an arranged view only when that changes it: a stack view that is told to hide a view it already hides,
    /// inside an animation, loses count and leaves the view shown or overlapping.
    private static func setShown(_ view: UIView, _ shown: Bool) {
        if view.isHidden == shown { view.isHidden = !shown }
    }

    private func updateEyebrow() {
        guard let base = eyebrowBase else { return }
        guard let since = content.runningSince else {
            eyebrowLabel.text = base
            return
        }
        eyebrowLabel.text = "\(base) · \(SportsCopy.duration(Int(Date().timeIntervalSince(since))))"
    }

    /// Ticks once a second while research runs and the stage is on screen, and stops otherwise.
    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, content.runningSince != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEyebrow() }
        }
    }

    private static func lineView(_ line: TVSportsStageContent.Line) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: line.symbol))
        icon.tintColor = line.tint
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.row, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = UILabel()
        title.text = line.title
        title.font = line.emphasized ? TVFont.cardTitle : TVFont.cardSubtitle
        title.textColor = line.emphasized ? Theme.Color.label : Theme.Color.labelSecondary
        title.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [title])
        text.axis = .vertical
        text.spacing = 2
        if let detail = line.detail, !detail.isEmpty {
            let label = UILabel()
            label.text = detail
            label.font = TVFont.cardSubtitle
            label.textColor = Theme.Color.labelTertiary
            label.numberOfLines = 3
            text.addArrangedSubview(label)
        }
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Space.s
        return row
    }

    private var spokenText: String {
        var parts: [String?] = [SportsCopy.title, eyebrowLabel.text, content.heading]
        if let art = content.art { parts.append(SportsCopy.becomes(art.file, art.title)) }
        parts.append(content.body)
        parts += content.lines.map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ", ") }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
