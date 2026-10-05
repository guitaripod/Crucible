import UIKit

struct EpisodeContentConfiguration: UIContentConfiguration {
    var episodeNumber: Int?
    var title: String = ""
    var summary: String?
    var thumbPath: String?
    var durationSecs: Double = 0
    var positionSecs: Double = 0
    var isWatched = false
    var isUpNext = false
    var progress: Double?
    var downloadState: DownloadRingButton.State = .idle
    var showsDownloadControl = true
    var downloadMenu: UIMenu?
    var onDownloadTap: ((UIView) -> Void)?
    var accessibilityActions: [UIAccessibilityCustomAction] = []

    func makeContentView() -> UIView & UIContentView {
        EpisodeContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> EpisodeContentConfiguration {
        self
    }
}

final class EpisodeContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static let thumbWidth = Theme.Size.episodeThumbWidth
    private static let thumbHeight: CGFloat = 74

    private let rowStack = UIStackView()
    private let thumbContainer = UIView()
    private let thumbImageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let watchedBadge = UIView()
    private let thumbProgress = ProgressBar()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let summaryLabel = UILabel()
    private let ring = DownloadRingButton()
    private var imageTask: Task<Void, Never>?
    private var currentThumbPath: String? = "__unset__"

    init(configuration: EpisodeContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        thumbContainer.layer.cornerRadius = Theme.Radius.s
        thumbContainer.layer.cornerCurve = .continuous
        thumbContainer.layer.borderWidth = 1
        thumbContainer.layer.borderColor = Theme.Color.artHairline.cgColor
        thumbContainer.clipsToBounds = true
        thumbContainer.backgroundColor = Theme.Color.surfaceRaised
        thumbContainer.translatesAutoresizingMaskIntoConstraints = false

        thumbImageView.contentMode = .scaleAspectFill
        thumbImageView.clipsToBounds = true
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderIcon.image = UIImage(systemName: "tv")
        placeholderIcon.tintColor = Theme.Color.labelTertiary
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        watchedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        watchedBadge.layer.cornerRadius = 11
        watchedBadge.isHidden = true
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .heavy)))
        check.tintColor = Theme.Color.onArt
        check.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.addSubview(check)

        thumbProgress.style = .onArt
        thumbProgress.isHidden = true
        thumbProgress.translatesAutoresizingMaskIntoConstraints = false

        thumbContainer.addSubview(placeholderIcon)
        thumbContainer.addSubview(thumbImageView)
        thumbContainer.addSubview(thumbProgress)
        thumbContainer.addSubview(watchedBadge)

        eyebrowLabel.adjustsFontForContentSizeCategory = true
        titleLabel.font = Theme.Font.episodeTitle
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        metaLabel.font = Theme.Font.footnote
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.numberOfLines = 0
        summaryLabel.font = Theme.Font.footnote
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = Theme.Color.labelSecondary
        summaryLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, metaLabel, summaryLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.setCustomSpacing(4, after: metaLabel)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        ring.diameter = 36
        ring.setContentHuggingPriority(.required, for: .horizontal)
        ring.setContentCompressionResistancePriority(.required, for: .horizontal)
        ring.isAccessibilityElement = false
        ring.addAction(UIAction { [weak self] _ in
            guard let self, let config = self.configuration as? EpisodeContentConfiguration else { return }
            config.onDownloadTap?(self.ring)
        }, for: .primaryActionTriggered)

        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = Theme.Space.s
        rowStack.addArrangedSubview(thumbContainer)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(ring)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            thumbContainer.widthAnchor.constraint(equalToConstant: Self.thumbWidth),
            thumbContainer.heightAnchor.constraint(equalToConstant: Self.thumbHeight),

            thumbImageView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            thumbImageView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumbContainer.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumbContainer.centerYAnchor),

            watchedBadge.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: -6),
            watchedBadge.topAnchor.constraint(equalTo: thumbContainer.topAnchor, constant: 6),
            watchedBadge.widthAnchor.constraint(equalToConstant: 22),
            watchedBadge.heightAnchor.constraint(equalToConstant: 22),
            check.centerXAnchor.constraint(equalTo: watchedBadge.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: watchedBadge.centerYAnchor),

            thumbProgress.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbProgress.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbProgress.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),
            thumbProgress.heightAnchor.constraint(equalToConstant: 4),

            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EpisodeContentView, _: UITraitCollection) in
            view.thumbContainer.layer.borderColor = Theme.Color.artHairline.cgColor
        }
    }

    private func apply() {
        guard let config = configuration as? EpisodeContentConfiguration else { return }
        let inProgress = !config.isWatched && (config.progress ?? 0) > 0
        let isDownloading: Bool
        switch config.downloadState {
        case .progress, .queued: isDownloading = true
        default: isDownloading = false
        }

        let number = config.episodeNumber.map { "E\($0)" } ?? "EPISODE"
        let eyebrowText: String
        let eyebrowColor: UIColor
        if config.isWatched {
            eyebrowText = "\(number) · WATCHED"
            eyebrowColor = Theme.Color.labelTertiary
        } else if inProgress {
            eyebrowText = "\(number) · CONTINUE"
            eyebrowColor = Theme.Color.accentText
        } else if isDownloading {
            eyebrowText = "\(number) · DOWNLOADING"
            eyebrowColor = Theme.Color.labelTertiary
        } else if config.isUpNext {
            eyebrowText = "\(number) · UP NEXT"
            eyebrowColor = Theme.Color.accentText
        } else {
            eyebrowText = number
            eyebrowColor = Theme.Color.labelTertiary
        }
        eyebrowLabel.attributedText = DetailFormat.eyebrow(eyebrowText, color: eyebrowColor)
        titleLabel.text = config.title
        summaryLabel.text = config.summary
        summaryLabel.isHidden = (config.summary ?? "").isEmpty

        var meta: [String] = []
        if let runtime = DetailFormat.runtime(config.durationSecs) { meta.append(runtime) }
        if inProgress, let left = DetailFormat.remaining(position: config.positionSecs, duration: config.durationSecs) {
            meta.append(left)
        }
        switch config.downloadState {
        case .progress(let value): meta.append("\(Int((value * 100).rounded()))%")
        case .queued: meta.append("Queued")
        case .paused(let value): meta.append("Paused · \(Int((value * 100).rounded()))%")
        case .completed: meta.append("Downloaded")
        case .failed: meta.append("Download failed")
        case .idle: break
        }
        metaLabel.text = meta.joined(separator: " · ")
        metaLabel.isHidden = meta.isEmpty

        watchedBadge.isHidden = !config.isWatched
        thumbProgress.isHidden = !inProgress
        thumbProgress.progress = config.progress ?? 0
        rowStack.alpha = config.isWatched ? 0.55 : 1

        ring.isHidden = !config.showsDownloadControl
        ring.set(config.downloadState)
        ring.menu = config.downloadMenu
        ring.showsMenuAsPrimaryAction = false

        accessibilityLabel = Self.spokenDescription(config, inProgress: inProgress)
        accessibilityCustomActions = config.accessibilityActions
        loadThumb(config.thumbPath)
    }

    private static func spokenDescription(_ config: EpisodeContentConfiguration, inProgress: Bool) -> String {
        var parts: [String] = []
        if let number = config.episodeNumber { parts.append("Episode \(number)") }
        parts.append(config.title)
        if config.isWatched {
            parts.append("watched")
        } else if inProgress, let left = DetailFormat.spokenDuration(config.durationSecs - config.positionSecs) {
            parts.append("\(left) left")
        } else if let duration = DetailFormat.spokenDuration(config.durationSecs) {
            parts.append(duration)
        }
        switch config.downloadState {
        case .progress(let value): parts.append("downloading \(Int((value * 100).rounded())) percent")
        case .queued: parts.append("download queued")
        case .paused(let value): parts.append("download paused at \(Int((value * 100).rounded())) percent")
        case .completed: parts.append("downloaded")
        case .failed: parts.append("download failed")
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }

    private func loadThumb(_ path: String?) {
        guard path != currentThumbPath else { return }
        imageTask?.cancel()
        imageTask = nil
        currentThumbPath = path
        thumbImageView.image = nil
        placeholderIcon.isHidden = false

        guard let path, !path.isEmpty else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: Int(Self.thumbWidth * 3))
            guard !Task.isCancelled, let self, let image else { return }
            self.thumbImageView.image = image
            self.placeholderIcon.isHidden = true
        }
    }
}
