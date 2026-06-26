import UIKit

struct EpisodeContentConfiguration: UIContentConfiguration, Hashable {
    var episodeNumber: Int?
    var title: String = ""
    var summary: String?
    var duration: String?
    var thumbPath: String?
    var isWatched: Bool = false
    var progress: Double?

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

    private let thumbContainer = UIView()
    private let thumbImageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let watchedScrim = UIView()
    private let watchedBadge = UIImageView()
    private let thumbProgress = ProgressBar()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let metaLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var currentThumbPath: String? = "__unset__"

    private static let thumbWidth: CGFloat = 132

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
        thumbContainer.layer.cornerRadius = 8
        thumbContainer.layer.cornerCurve = .continuous
        thumbContainer.clipsToBounds = true
        thumbContainer.backgroundColor = .secondarySystemBackground
        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.setContentHuggingPriority(.required, for: .horizontal)

        thumbImageView.contentMode = .scaleAspectFill
        thumbImageView.clipsToBounds = true
        thumbImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderIcon.image = UIImage(systemName: "tv")
        placeholderIcon.tintColor = .quaternaryLabel
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        watchedScrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        watchedScrim.isHidden = true
        watchedScrim.translatesAutoresizingMaskIntoConstraints = false

        watchedBadge.image = UIImage(systemName: "checkmark.circle.fill")
        watchedBadge.tintColor = .systemGreen
        watchedBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        watchedBadge.contentMode = .scaleAspectFit
        watchedBadge.isHidden = true
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false

        thumbProgress.translatesAutoresizingMaskIntoConstraints = false
        thumbProgress.isHidden = true

        eyebrowLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        eyebrowLabel.textColor = .systemOrange

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 2

        metaLabel.font = .systemFont(ofSize: 12, weight: .medium)
        metaLabel.textColor = .tertiaryLabel

        thumbContainer.addSubview(placeholderIcon)
        thumbContainer.addSubview(thumbImageView)
        thumbContainer.addSubview(watchedScrim)
        thumbContainer.addSubview(thumbProgress)
        thumbContainer.addSubview(watchedBadge)

        let textStack = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, summaryLabel, metaLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.setCustomSpacing(8, after: summaryLabel)

        let mainStack = UIStackView(arrangedSubviews: [thumbContainer, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .top
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)

        NSLayoutConstraint.activate([
            thumbContainer.widthAnchor.constraint(equalToConstant: Self.thumbWidth),
            thumbContainer.heightAnchor.constraint(equalTo: thumbContainer.widthAnchor, multiplier: 9.0 / 16.0),

            thumbImageView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            thumbImageView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumbContainer.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumbContainer.centerYAnchor),

            watchedScrim.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            watchedScrim.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            watchedScrim.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            watchedScrim.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),

            watchedBadge.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor, constant: -6),
            watchedBadge.topAnchor.constraint(equalTo: thumbContainer.topAnchor, constant: 6),

            thumbProgress.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbProgress.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
            thumbProgress.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),

            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func apply() {
        guard let config = configuration as? EpisodeContentConfiguration else { return }

        eyebrowLabel.text = config.episodeNumber.map { "EPISODE \($0)" } ?? "EPISODE"
        titleLabel.text = config.title
        summaryLabel.text = config.summary
        summaryLabel.isHidden = (config.summary ?? "").isEmpty

        var metaParts = [String]()
        if let duration = config.duration { metaParts.append(duration) }

        if config.isWatched {
            watchedBadge.isHidden = false
            watchedScrim.isHidden = false
            thumbProgress.isHidden = true
            titleLabel.textColor = .secondaryLabel
            eyebrowLabel.textColor = .systemGreen
            metaParts.append("Watched")
        } else if let progress = config.progress, progress > 0 {
            watchedBadge.isHidden = true
            watchedScrim.isHidden = true
            thumbProgress.isHidden = false
            thumbProgress.progress = progress
            titleLabel.textColor = .label
            eyebrowLabel.textColor = .systemOrange
            metaParts.append("\(Int(progress * 100))% watched")
        } else {
            watchedBadge.isHidden = true
            watchedScrim.isHidden = true
            thumbProgress.isHidden = true
            titleLabel.textColor = .label
            eyebrowLabel.textColor = .systemOrange
        }

        metaLabel.text = metaParts.joined(separator: " · ")
        metaLabel.isHidden = metaParts.isEmpty

        loadThumb(config.thumbPath)
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
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: Int(Self.thumbWidth * 2))
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.thumbImageView.image = image
                self.placeholderIcon.isHidden = true
            }
        }
    }
}
