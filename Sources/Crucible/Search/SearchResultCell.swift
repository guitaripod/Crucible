@preconcurrency import UIKit

struct SearchResultConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var blurhash: String?
    var title: String = ""
    var subtitle: String?
    var mediaType: String = ""
    var baseURL: URL?

    func makeContentView() -> UIView & UIContentView {
        SearchResultContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SearchResultConfiguration {
        self
    }
}

final class SearchResultContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet {
            imageTask?.cancel()
            apply()
        }
    }

    private let posterImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let typeBadge = UILabel()
    private let placeholderView = UIImageView()
    private var imageTask: Task<Void, Never>?

    init(configuration: SearchResultConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterImageView.layer.cornerRadius = 6
        posterImageView.backgroundColor = .systemGray6
        posterImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.image = UIImage(systemName: "film")
        placeholderView.tintColor = .systemGray3
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel

        typeBadge.font = .systemFont(ofSize: 11, weight: .medium)
        typeBadge.textColor = .white
        typeBadge.backgroundColor = .systemBlue
        typeBadge.layer.cornerRadius = 4
        typeBadge.clipsToBounds = true
        typeBadge.textAlignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, typeBadge])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let mainStack = UIStackView(arrangedSubviews: [posterImageView, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        posterImageView.addSubview(placeholderView)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            posterImageView.widthAnchor.constraint(equalToConstant: 50),
            posterImageView.heightAnchor.constraint(equalToConstant: 75),

            placeholderView.centerXAnchor.constraint(equalTo: posterImageView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: posterImageView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 20),
            placeholderView.heightAnchor.constraint(equalToConstant: 20),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? SearchResultConfiguration else { return }
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = config.subtitle == nil

        let typeText: String
        switch config.mediaType {
        case "movie": typeText = " Movie "
        case "episode": typeText = " Episode "
        case "show": typeText = " Show "
        default: typeText = " \(config.mediaType) "
        }
        typeBadge.text = typeText

        posterImageView.image = nil
        placeholderView.isHidden = false

        if let blurhash = config.blurhash, let decoded = BlurhashDecoder.decode(blurhash) {
            posterImageView.image = decoded
            placeholderView.isHidden = true
        }

        guard let posterPath = config.posterPath, let baseURL = config.baseURL else { return }

        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: posterPath, size: "w185", baseURL: baseURL)
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.posterImageView.image = image
                self.placeholderView.isHidden = true
            }
        }
    }
}
