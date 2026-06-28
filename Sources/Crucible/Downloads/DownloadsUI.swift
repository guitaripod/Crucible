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

struct DownloadRowConfiguration: UIContentConfiguration {
    var ratingKey: String
    var title: String
    var subtitle: String?
    var status: String?
    var progress: Double?
    var isError: Bool = false
    var isCompleted: Bool = false
    var placeholderIcon: String = "film"

    func makeContentView() -> UIView & UIContentView {
        DownloadRowView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DownloadRowConfiguration { self }
}

final class DownloadRowView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let posterContainer = UIView()
    private let posterImageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressBar = ProgressBar()
    private var imageTask: Task<Void, Never>?
    private var currentPosterKey: String?

    private static let posterWidth: CGFloat = 46

    init(configuration: DownloadRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        posterContainer.layer.cornerRadius = 6
        posterContainer.layer.cornerCurve = .continuous
        posterContainer.clipsToBounds = true
        posterContainer.backgroundColor = .secondarySystemBackground
        posterContainer.translatesAutoresizingMaskIntoConstraints = false
        posterContainer.setContentHuggingPriority(.required, for: .horizontal)

        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderIcon.tintColor = .quaternaryLabel
        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .light)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .tertiaryLabel
        statusLabel.numberOfLines = 1

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        posterContainer.addSubview(posterImageView)
        posterContainer.addSubview(placeholderIcon)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, statusLabel, progressBar])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setCustomSpacing(6, after: statusLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = UIStackView(arrangedSubviews: [posterContainer, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)

        NSLayoutConstraint.activate([
            posterContainer.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            posterContainer.heightAnchor.constraint(equalTo: posterContainer.widthAnchor, multiplier: 3.0 / 2.0),

            posterImageView.topAnchor.constraint(equalTo: posterContainer.topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: posterContainer.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: posterContainer.trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: posterContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: posterContainer.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: posterContainer.centerYAnchor),

            progressBar.heightAnchor.constraint(equalToConstant: 4),

            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func apply() {
        guard let config = configuration as? DownloadRowConfiguration else { return }

        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty

        statusLabel.text = config.status
        statusLabel.isHidden = (config.status ?? "").isEmpty
        statusLabel.textColor = config.isError ? .systemRed : (config.isCompleted ? .systemGreen : .systemOrange)

        if let progress = config.progress {
            progressBar.isHidden = false
            progressBar.progress = progress
        } else {
            progressBar.isHidden = true
        }

        if config.ratingKey != currentPosterKey {
            currentPosterKey = config.ratingKey
            imageTask?.cancel()
            posterImageView.image = nil
            placeholderIcon.isHidden = false
            placeholderIcon.image = UIImage(systemName: config.placeholderIcon)
            let key = config.ratingKey
            imageTask = Task { [weak self] in
                let image = await OfflinePoster.image(ratingKey: key)
                guard !Task.isCancelled, let self else { return }
                if let image {
                    self.posterImageView.image = image
                    self.placeholderIcon.isHidden = true
                }
            }
        }
    }
}
