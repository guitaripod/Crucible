@preconcurrency import UIKit

struct PosterContentConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var blurhash: String?
    var title: String = ""
    var subtitle: String?
    var baseURL: URL?
    var progress: Double?
    var placeholderIcon: String = "film"

    func makeContentView() -> UIView & UIContentView {
        PosterContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> PosterContentConfiguration {
        self
    }
}

final class PosterContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet {
            imageTask?.cancel()
            apply()
        }
    }

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressBar = ProgressBar()
    private let placeholderView = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(configuration: PosterContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.backgroundColor = .systemGray6
        imageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.image = UIImage(systemName: "film")
        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24)
        placeholderView.tintColor = .systemGray3
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [imageView, textStack])
        mainStack.axis = .vertical
        mainStack.spacing = 6
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        imageView.addSubview(placeholderView)
        imageView.addSubview(progressBar)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 3.0 / 2.0),

            placeholderView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 32),
            placeholderView.heightAnchor.constraint(equalToConstant: 32),

            progressBar.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? PosterContentConfiguration else { return }
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = config.subtitle == nil

        if let progress = config.progress, progress > 0 {
            progressBar.isHidden = false
            progressBar.progress = progress
        } else {
            progressBar.isHidden = true
        }

        imageView.image = nil
        placeholderView.isHidden = false
        placeholderView.image = UIImage(systemName: config.placeholderIcon)

        if let blurhash = config.blurhash {
            if let decoded = BlurhashDecoder.decode(blurhash) {
                imageView.image = decoded
                placeholderView.isHidden = true
            }
        }

        guard let posterPath = config.posterPath, let baseURL = config.baseURL else { return }

        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: posterPath, size: "w342", baseURL: baseURL)
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.imageView.image = image
                self.placeholderView.isHidden = true
            }
        }
    }
}
