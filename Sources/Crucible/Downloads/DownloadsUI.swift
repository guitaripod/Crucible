@preconcurrency import UIKit

/// Builds a context-menu action that downloads, cancels, or removes a download for a media item,
/// reused across grids and detail screens so the behaviour stays consistent everywhere.
@MainActor
enum DownloadMenu {
    static func action(for metadata: PlexMetadata, quality: DownloadQuality? = nil) -> UIMenuElement {
        let item = DownloadManager.shared.item(for: metadata.id)
        switch item?.state {
        case .completed:
            return UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                DownloadManager.shared.delete(metadata.id)
            }
        case .some(let state) where state != .failed:
            return UIAction(title: "Cancel Download", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { _ in
                DownloadManager.shared.delete(metadata.id)
            }
        default:
            return UIAction(title: "Download", image: UIImage(systemName: "arrow.down.circle")) { _ in
                DownloadManager.shared.enqueue(metadata: metadata, quality: quality)
            }
        }
    }
}

/// Loads a poster that was saved to disk alongside a download, so the Downloads UI renders fully offline.
enum OfflinePoster {
    static func image(ratingKey: String) async -> UIImage? {
        let url = DownloadPaths.posterURL(ratingKey: ratingKey)
        let raw = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard let raw else { return nil }
        return await raw.byPreparingForDisplay() ?? raw
    }
}

extension DownloadItem {
    var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var statusLine: String {
        switch state {
        case .queued:
            return "Queued · \(quality.shortLabel)"
        case .waitingForWiFi:
            return "Waiting for Wi-Fi · \(quality.shortLabel)"
        case .downloading:
            return "Downloading · \(percentText)"
        case .paused:
            return "Paused · \(percentText)"
        case .failed:
            return errorMessage ?? "Download failed"
        case .completed:
            var parts = [quality.shortLabel]
            if totalBytes > 0 { parts.append(Formatters.fileSize(totalBytes)) }
            if isWatched { parts.append("Watched") }
            return parts.joined(separator: " · ")
        }
    }

    var progressForDisplay: Double? {
        switch state {
        case .downloading, .paused, .queued, .waitingForWiFi: return progress
        case .completed, .failed: return nil
        }
    }
}


/// Plays a downloaded item through the shared offline path, or explains that its files are gone.
@MainActor
enum OfflinePlayback {
    static func start(_ item: DownloadItem, api: APIClient, from host: UIViewController) -> PlayerCoordinator? {
        guard let asset = DownloadManager.shared.offlineAsset(for: item.ratingKey) else {
            let alert = UIAlertController(title: "File Missing", message: "This download could not be found on disk. Try downloading it again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            host.present(alert, animated: true)
            return nil
        }
        let meta = PlayerCoordinator.Metadata(
            title: item.title,
            showName: item.showTitle,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            posterPath: item.plexThumbPath,
            duration: item.durationSecs
        )
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: item.ratingKey,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumePosition: item.resumeSecs,
            metadata: meta,
            offlineAsset: asset
        )
        coordinator.present(from: host)
        return coordinator
    }
}

/// Smoothed bytes-per-second per active download, derived from the progress events the manager emits.
/// HLS segments commit in bursts, so the rate is an exponential moving average over samples at least
/// half a second apart.
struct DownloadRateTracker {
    private struct Sample {
        var bytes: Int64
        var at: Date
        var rate: Double
    }

    private var samples: [String: Sample] = [:]

    mutating func record(ratingKey: String, bytes: Int64, now: Date = Date()) {
        guard var sample = samples[ratingKey] else {
            samples[ratingKey] = Sample(bytes: bytes, at: now, rate: 0)
            return
        }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= 0.5 else { return }
        let delta = Double(bytes - sample.bytes)
        if delta > 0 {
            let instantaneous = delta / elapsed
            sample.rate = sample.rate == 0 ? instantaneous : 0.3 * instantaneous + 0.7 * sample.rate
        } else {
            sample.rate *= 0.7
        }
        sample.bytes = bytes
        sample.at = now
        samples[ratingKey] = sample
    }

    func rate(for ratingKey: String) -> Double? {
        guard let rate = samples[ratingKey]?.rate, rate > 1 else { return nil }
        return rate
    }

    mutating func keepOnly(_ ratingKeys: Set<String>) {
        samples = samples.filter { ratingKeys.contains($0.key) }
    }
}

/// Free space, Crucible's share and total volume capacity, captured together for the storage card.
struct StorageSnapshot: Equatable {
    var usedBytes: Int64 = 0
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0

    @MainActor
    static func capture() async -> StorageSnapshot {
        let used = await DownloadManager.shared.totalBytesOnDisk()
        let free = await DownloadManager.shared.availableCapacity()
        return StorageSnapshot(usedBytes: used, freeBytes: free, totalBytes: totalCapacity())
    }

    private static func totalCapacity() -> Int64 {
        let probe = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? probe.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }
}

enum DownloadFormat {
    /// "2 h 05 m" for a runtime, "45 m" below an hour.
    static func runtime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? String(format: "%d h %02d m", hours, minutes) : "\(max(minutes, 1)) m"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / 1_048_576
        if megabytes >= 1 { return String(format: "%.1f MB/s", megabytes) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    static func remaining(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "< 1 min left" }
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h left" : "\(hours) h \(rest) min left"
    }
}

struct DownloadRowConfiguration: UIContentConfiguration {
    enum Tone {
        case ember
        case secondary
        case tertiary
        case error
    }

    var posterKey: String
    var title: String
    var subtitle: String?
    var status: String?
    var statusTone: Tone = .ember
    var statusSymbol: String?
    var progress: Double?
    var ring: DownloadRingButton.State?
    var ringHint: String?
    var onRingTap: (() -> Void)?
    var isStacked = false
    var placeholderIcon = "film"
    var contentAlpha: CGFloat = 1
    var isEditing = false

    func makeContentView() -> UIView & UIContentView {
        DownloadRowView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DownloadRowConfiguration {
        var copy = self
        copy.isEditing = (state as? UICellConfigurationState)?.isEditing ?? false
        return copy
    }
}

/// Poster thumbnail loaded from the on-disk copy saved with the download. When `isStacked` it draws
/// two offset ghost cards behind the poster to signal a group of episodes.
final class DownloadThumbView: UIView {
    private static let posterSize = CGSize(width: 44, height: 66)

    private let backCard = UIView()
    private let midCard = UIView()
    private let posterContainer = UIView()
    private let imageView = UIImageView()
    private let placeholder = UIImageView()
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var posterTopConstraint: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?
    private var currentKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        for card in [backCard, midCard, posterContainer] {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.layer.cornerRadius = 7
            card.layer.cornerCurve = .continuous
            addSubview(card)
        }
        backCard.backgroundColor = Theme.Color.surfaceHigh
        midCard.backgroundColor = Theme.Color.surfaceRaised
        midCard.layer.borderWidth = 1
        midCard.layer.borderColor = Theme.Color.separator.cgColor
        posterContainer.backgroundColor = Theme.Color.surfaceRaised
        posterContainer.clipsToBounds = true
        posterContainer.layer.borderWidth = 1
        posterContainer.layer.borderColor = Theme.Color.separator.cgColor

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.tintColor = Theme.Color.labelTertiary
        placeholder.contentMode = .scaleAspectFit
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .light)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        posterContainer.addSubview(imageView)
        posterContainer.addSubview(placeholder)

        let size = Self.posterSize
        let width = widthAnchor.constraint(equalToConstant: size.width)
        let height = heightAnchor.constraint(equalToConstant: size.height)
        let top = posterContainer.topAnchor.constraint(equalTo: topAnchor)
        widthConstraint = width
        heightConstraint = height
        posterTopConstraint = top

        NSLayoutConstraint.activate([
            width, height, top,
            posterContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterContainer.widthAnchor.constraint(equalToConstant: size.width),
            posterContainer.heightAnchor.constraint(equalToConstant: size.height),

            midCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            midCard.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            midCard.widthAnchor.constraint(equalToConstant: size.width),
            midCard.heightAnchor.constraint(equalToConstant: size.height),

            backCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backCard.topAnchor.constraint(equalTo: topAnchor),
            backCard.widthAnchor.constraint(equalToConstant: size.width),
            backCard.heightAnchor.constraint(equalToConstant: size.height),

            imageView.topAnchor.constraint(equalTo: posterContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: posterContainer.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: posterContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: posterContainer.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: posterContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: posterContainer.centerYAnchor),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DownloadThumbView, _: UITraitCollection) in
            view.midCard.layer.borderColor = Theme.Color.separator.cgColor
            view.posterContainer.layer.borderColor = Theme.Color.separator.cgColor
        }
    }

    func configure(posterKey: String, placeholderIcon: String, isStacked: Bool) {
        let size = Self.posterSize
        widthConstraint?.constant = isStacked ? size.width + 8 : size.width
        heightConstraint?.constant = isStacked ? size.height + 4 : size.height
        posterTopConstraint?.constant = isStacked ? 4 : 0
        backCard.isHidden = !isStacked
        midCard.isHidden = !isStacked
        placeholder.image = UIImage(systemName: placeholderIcon)

        let missing = imageView.image == nil && imageTask == nil
        guard posterKey != currentKey || missing else { return }
        currentKey = posterKey
        imageTask?.cancel()
        imageView.image = nil
        placeholder.isHidden = false
        imageTask = Task { [weak self] in
            let image = await OfflinePoster.image(ratingKey: posterKey)
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.imageView.image = image
                self.placeholder.isHidden = true
            }
            self.imageTask = nil
        }
    }
}

final class DownloadRowView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let thumb = DownloadThumbView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressBar = ProgressBar()
    private let ringButton = DownloadRingButton()
    private let contentStack = UIStackView()
    private var onRingTap: (() -> Void)?

    init(configuration: DownloadRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        titleLabel.font = Theme.Font.scaled(.callout, 16, .semibold)
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Font.footnote
        subtitleLabel.textColor = Theme.Color.labelSecondary
        statusLabel.font = Theme.Font.caption1
        for label in [titleLabel, subtitleLabel, statusLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        progressBar.style = .onSurface
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progressBar, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setCustomSpacing(7, after: subtitleLabel)
        textStack.setCustomSpacing(5, after: progressBar)

        ringButton.addAction(UIAction { [weak self] _ in self?.onRingTap?() }, for: .primaryActionTriggered)
        ringButton.setContentHuggingPriority(.required, for: .horizontal)
        thumb.setContentHuggingPriority(.required, for: .horizontal)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(thumb)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(ringButton)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DownloadRowView, _: UITraitCollection) in
            view.apply()
        }
    }

    private func apply() {
        guard let config = configuration as? DownloadRowConfiguration else { return }

        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty

        let tone = Self.color(for: config.statusTone)
        if let status = config.status, !status.isEmpty {
            statusLabel.attributedText = Self.statusText(status, symbol: config.statusSymbol, color: tone, font: statusLabel.font)
            statusLabel.isHidden = false
        } else {
            statusLabel.attributedText = nil
            statusLabel.isHidden = true
        }

        if let progress = config.progress {
            progressBar.isHidden = false
            progressBar.progress = progress
        } else {
            progressBar.isHidden = true
        }

        thumb.configure(posterKey: config.posterKey, placeholderIcon: config.placeholderIcon, isStacked: config.isStacked)

        onRingTap = config.onRingTap
        if let ring = config.ring, !config.isEditing {
            ringButton.isHidden = false
            ringButton.set(ring, animated: !UIAccessibility.isReduceMotionEnabled)
            if let hint = config.ringHint { ringButton.accessibilityLabel = hint }
        } else {
            ringButton.isHidden = true
        }
        contentStack.alpha = config.contentAlpha
    }

    private static func color(for tone: DownloadRowConfiguration.Tone) -> UIColor {
        switch tone {
        case .ember: return Theme.Color.accentText
        case .secondary: return Theme.Color.labelSecondary
        case .tertiary: return Theme.Color.labelTertiary
        case .error: return Theme.Color.destructive
        }
    }

    private static func statusText(_ text: String, symbol: String?, color: UIColor, font: UIFont) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: font]
        let result = NSMutableAttributedString()
        if let symbol, let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font)) {
            let attachment = NSTextAttachment(image: image.withTintColor(color, renderingMode: .alwaysOriginal))
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: attributes))
        }
        result.append(NSAttributedString(string: text, attributes: attributes))
        return result
    }
}
