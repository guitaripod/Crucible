@preconcurrency import UIKit

/// Bottom sheet for downloading part of a show: which episodes, at what quality, and whether to keep
/// the next few downloaded automatically.
final class DownloadOptionsSheetViewController: UIViewController {
    struct Context {
        let showRatingKey: String
        let showTitle: String
        let seasonTitle: String
        let posterPath: String?
        let episodes: [PlexMetadata]
    }

    private enum Scope: Int, CaseIterable {
        case all
        case unwatched
        case next
    }

    private static let nextCount = 3

    private let context: Context
    private let onFinish: () -> Void
    private let episodes: [PlexMetadata]
    private let initialKeepCount: Int
    private var scope: Scope
    private var quality: DownloadQuality = Preferences.downloadQuality
    private var keepNext: Bool
    private var freeBytes: Int64 = 0
    private var posterTask: Task<Void, Never>?

    private let posterView = UIImageView()
    private let segmented = UISegmentedControl()
    private let qualityButton = UIButton()
    private let keepSwitch = UISwitch()
    private let wifiSwitch = UISwitch()
    private let keepTitleLabel = UILabel()
    private let estimateLabel = UILabel()
    private let confirmButton = ThemeButton.primary(title: "Download")

    init(context: Context, onFinish: @escaping () -> Void) {
        self.context = context
        self.onFinish = onFinish
        self.episodes = context.episodes.sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }
        let stored = AutoDownloadPolicy.count(forShow: context.showRatingKey)
        self.initialKeepCount = stored
        self.keepNext = stored > 0
        let hasUnwatched = context.episodes.contains { !$0.isWatched }
        self.scope = hasUnwatched ? .unwatched : .all
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        configureSheet()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { posterTask?.cancel() }

    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        if #unavailable(iOS 26.0) {
            sheet.preferredCornerRadius = 32
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #unavailable(iOS 26.0) {
            view.backgroundColor = Theme.Color.canvas
        }
        view.tintColor = Theme.Color.accent
        buildLayout()
        refreshAll()
        loadPoster()
        loadFreeSpace()
    }

    private var selectedEpisodes: [PlexMetadata] {
        switch scope {
        case .all: return episodes
        case .unwatched: return episodes.filter { !$0.isWatched }
        case .next: return Array(episodes.filter { !$0.isWatched }.prefix(Self.nextCount))
        }
    }

    /// Selected episodes that are not already downloaded or queued.
    private var pendingEpisodes: [PlexMetadata] {
        selectedEpisodes.filter { DownloadManager.shared.item(for: $0.id) == nil }
    }

    private var keepCount: Int {
        initialKeepCount > 0 ? initialKeepCount : AutoDownloadPolicy.defaultCount
    }

    private var keepChanged: Bool { keepNext != (initialKeepCount > 0) }

    private func buildLayout() {
        let header = makeHeader()
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = UIStackView(arrangedSubviews: [makeSummaryRow(), makeSegmented(), makeOptionsCard()])
        content.axis = .vertical
        content.spacing = 14
        content.setCustomSpacing(8, after: content.arrangedSubviews[0])
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        estimateLabel.font = Theme.Font.footnote
        estimateLabel.textColor = Theme.Color.labelSecondary
        estimateLabel.textAlignment = .center
        estimateLabel.numberOfLines = 0
        estimateLabel.adjustsFontForContentSizeCategory = true
        confirmButton.addAction(UIAction { [weak self] _ in self?.confirm() }, for: .primaryActionTriggered)

        let footer = UIStackView(arrangedSubviews: [estimateLabel, confirmButton])
        footer.axis = .vertical
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scroll)
        view.addSubview(footer)

        let inset = Theme.Space.m + Theme.Space.xxs
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -inset * 2),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Space.s),
        ])
    }

    private func makeHeader() -> UIView {
        let title = UILabel()
        title.text = "Download"
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        let close = ThemeButton.icon(symbol: "xmark", label: "Close", size: 36)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [title, UIView(), close])
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeSummaryRow() -> UIView {
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.layer.cornerRadius = 7
        posterView.layer.cornerCurve = .continuous
        posterView.isAccessibilityElement = false
        posterView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            posterView.widthAnchor.constraint(equalToConstant: 44),
            posterView.heightAnchor.constraint(equalToConstant: 66),
        ])

        let title = UILabel()
        title.text = "\(context.showTitle) · \(context.seasonTitle)"
        title.font = Theme.Font.scaled(.callout, 16, .semibold)
        title.textColor = Theme.Color.label
        let watched = episodes.filter(\.isWatched).count
        let subtitle = UILabel()
        subtitle.text = "\(episodes.count) \(episodes.count == 1 ? "episode" : "episodes") · \(watched) watched"
        subtitle.font = Theme.Font.footnote
        subtitle.textColor = Theme.Color.labelSecondary
        for label in [title, subtitle] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [posterView, text])
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        return row
    }

    private func makeSegmented() -> UIView {
        segmented.removeAllSegments()
        for scope in Scope.allCases {
            segmented.insertSegment(withTitle: title(for: scope), at: scope.rawValue, animated: false)
        }
        segmented.selectedSegmentIndex = scope.rawValue
        segmented.selectedSegmentTintColor = Theme.Color.surfaceHigh
        segmented.backgroundColor = Theme.Color.surfaceRaised
        segmented.setTitleTextAttributes([.foregroundColor: Theme.Color.labelSecondary, .font: Theme.Font.scaled(.subheadline, 14, .semibold)], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: Theme.Color.label, .font: Theme.Font.scaled(.subheadline, 14, .semibold)], for: .selected)
        segmented.addAction(UIAction { [weak self] _ in
            guard let self, let next = Scope(rawValue: self.segmented.selectedSegmentIndex) else { return }
            self.scope = next
            Haptics.selection()
            self.refreshAll()
        }, for: .valueChanged)
        segmented.accessibilityLabel = "Episodes to download"
        segmented.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true
        return segmented
    }

    private func title(for scope: Scope) -> String {
        let unwatched = episodes.filter { !$0.isWatched }.count
        switch scope {
        case .all: return "All \(episodes.count)"
        case .unwatched: return "Unwatched \(unwatched)"
        case .next: return "Next \(min(Self.nextCount, unwatched))"
        }
    }

    private func makeOptionsCard() -> UIView {
        let rows = [makeQualityRow(), makeKeepRow(), makeWiFiRow()]
        let card = UIStackView()
        card.axis = .vertical
        for (index, row) in rows.enumerated() {
            if index > 0 { card.addArrangedSubview(makeSeparator()) }
            card.addArrangedSubview(row)
        }
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.Color.separator.cgColor
        card.clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (_: DownloadOptionsSheetViewController, _: UITraitCollection) in
            card.layer.borderColor = Theme.Color.separator.cgColor
        }
        return card
    }

    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
        return line
    }

    private func makeRow(_ arranged: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: arranged)
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        return row
    }

    private func rowLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.scaled(.callout, 16, .regular)
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func makeQualityRow() -> UIView {
        let label = rowLabel("Quality")
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        qualityButton.showsMenuAsPrimaryAction = true
        qualityButton.setContentHuggingPriority(.required, for: .horizontal)
        qualityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateQualityButton()
        return makeRow([label, UIView(), qualityButton])
    }

    private func qualityValue(_ quality: DownloadQuality) -> String {
        quality == .original ? quality.title : "\(quality.title) · \(quality.shortLabel)"
    }

    private func updateQualityButton() {
        var config = UIButton.Configuration.plain()
        config.title = qualityValue(quality)
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.labelSecondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.callout
            return outgoing
        }
        qualityButton.configuration = config
        qualityButton.menu = UIMenu(title: "Download Quality", children: DownloadQuality.allCases.map { option in
            UIAction(title: option.title, subtitle: option.detail, state: option == quality ? .on : .off) { [weak self] _ in
                self?.quality = option
                self?.updateQualityButton()
                self?.refreshAll()
            }
        })
        qualityButton.accessibilityLabel = "Quality, \(qualityValue(quality))"
    }

    private func makeKeepRow() -> UIView {
        keepTitleLabel.text = "Keep next \(keepCount) downloaded"
        keepTitleLabel.font = Theme.Font.scaled(.callout, 16, .regular)
        keepTitleLabel.textColor = Theme.Color.label
        let caption = UILabel()
        caption.text = "Fetches new episodes as you watch and removes watched ones."
        caption.font = Theme.Font.caption1Regular
        caption.textColor = Theme.Color.labelSecondary
        for label in [keepTitleLabel, caption] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [keepTitleLabel, caption])
        text.axis = .vertical
        text.spacing = 2

        keepSwitch.isOn = keepNext
        keepSwitch.onTintColor = Theme.Color.accent
        keepSwitch.setContentHuggingPriority(.required, for: .horizontal)
        keepSwitch.accessibilityLabel = "Keep next \(keepCount) downloaded"
        keepSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.keepNext = self.keepSwitch.isOn
            Haptics.selection()
            self.refreshAll()
        }, for: .valueChanged)
        return makeRow([text, keepSwitch])
    }

    private func makeWiFiRow() -> UIView {
        wifiSwitch.isOn = !Preferences.downloadOverCellular
        wifiSwitch.onTintColor = Theme.Color.accent
        wifiSwitch.setContentHuggingPriority(.required, for: .horizontal)
        wifiSwitch.accessibilityLabel = "Wi-Fi only"
        wifiSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Preferences.downloadOverCellular = !self.wifiSwitch.isOn
            DownloadManager.shared.cellularPreferenceChanged()
            Haptics.selection()
        }, for: .valueChanged)
        return makeRow([rowLabel("Wi-Fi only"), wifiSwitch])
    }

    private func refreshAll() {
        for scope in Scope.allCases {
            segmented.setTitle(title(for: scope), forSegmentAt: scope.rawValue)
        }
        let unwatched = episodes.filter { !$0.isWatched }.count
        segmented.setEnabled(unwatched > 0, forSegmentAt: Scope.unwatched.rawValue)
        segmented.setEnabled(unwatched > 0, forSegmentAt: Scope.next.rawValue)
        updateEstimate()
        updateConfirmButton()
    }

    private func updateEstimate() {
        let pending = pendingEpisodes
        let sizes = pending.compactMap { estimatedBytes(for: $0) }
        let size = sizes.isEmpty ? "—" : "≈ \(Formatters.fileSize(sizes.reduce(0, +)))"
        var parts = [size]
        if freeBytes > 0 { parts.append("\(Formatters.fileSize(freeBytes)) free") }
        estimateLabel.text = parts.joined(separator: " · ")
    }

    /// Source size scaled by how much smaller the chosen bitrate is than the file's own, never larger.
    private func estimatedBytes(for episode: PlexMetadata) -> Int64? {
        guard let source = episode.fileSize, source > 0 else { return nil }
        guard let kbps = quality.maxVideoBitrate else { return source }
        let seconds = episode.durationSecs
        guard seconds > 0 else { return source }
        let sourceBitsPerSecond = Double(source) * 8 / seconds
        let targetBitsPerSecond = Double(kbps) * 1000 + 192_000
        let factor = min(1, targetBitsPerSecond / sourceBitsPerSecond)
        return Int64(Double(source) * factor)
    }

    private func updateConfirmButton() {
        let count = pendingEpisodes.count
        let title: String
        let enabled: Bool
        if count > 0 {
            title = "Download \(count) \(count == 1 ? "Episode" : "Episodes")"
            enabled = true
        } else if keepChanged {
            title = "Save"
            enabled = true
        } else {
            title = selectedEpisodes.isEmpty ? "Download" : "Already Downloaded"
            enabled = false
        }
        var config = confirmButton.configuration ?? ThemeButton.primaryConfiguration(title: title)
        config.title = title
        confirmButton.configuration = config
        confirmButton.isEnabled = enabled
    }

    private func loadPoster() {
        guard let path = context.posterPath else { return }
        posterTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: 132)
            guard !Task.isCancelled, let self, let image else { return }
            self.posterView.image = image
        }
    }

    private func loadFreeSpace() {
        Task { [weak self] in
            let free = await DownloadManager.shared.availableCapacity()
            guard let self else { return }
            self.freeBytes = free
            self.updateEstimate()
        }
    }

    private func confirm() {
        let pending = pendingEpisodes
        if !pending.isEmpty {
            let added = DownloadManager.shared.enqueueAll(pending, quality: quality)
            AppLogger.notice("Download sheet queued \(added) episodes for show \(context.showRatingKey)", .persistence)
        }
        applyKeepNextChoice()
        Haptics.medium()
        dismiss(animated: true) { [onFinish] in onFinish() }
    }

    private func applyKeepNextChoice() {
        guard keepChanged || keepNext else { return }
        AutoDownloadPolicy.set(count: keepNext ? keepCount : 0, quality: quality, forShow: context.showRatingKey)
        if keepNext { AutoDownloadPolicy.shared.evaluateOnForeground() }
    }
}
