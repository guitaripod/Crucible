@preconcurrency import UIKit

struct SearchResultConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var title: String = ""
    var subtitle: String?
    var mediaType: String = ""

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
        posterImageView.layer.cornerRadius = 8
        posterImageView.layer.cornerCurve = .continuous
        posterImageView.backgroundColor = .secondarySystemBackground
        posterImageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.image = UIImage(systemName: "film")
        placeholderView.tintColor = .quaternaryLabel
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 2

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel

        typeBadge.font = .systemFont(ofSize: 10, weight: .bold)
        typeBadge.textColor = .white
        typeBadge.layer.cornerRadius = 4
        typeBadge.layer.cornerCurve = .continuous
        typeBadge.clipsToBounds = true
        typeBadge.textAlignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, typeBadge])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .leading

        let mainStack = UIStackView(arrangedSubviews: [posterImageView, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 14
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        posterImageView.addSubview(placeholderView)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            posterImageView.widthAnchor.constraint(equalToConstant: 54),
            posterImageView.heightAnchor.constraint(equalToConstant: 80),

            placeholderView.centerXAnchor.constraint(equalTo: posterImageView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: posterImageView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 22),
            placeholderView.heightAnchor.constraint(equalToConstant: 22),
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
        let badgeColor: UIColor
        switch config.mediaType {
        case "movie":
            typeText = " MOVIE "
            badgeColor = .systemOrange
        case "episode":
            typeText = " EPISODE "
            badgeColor = .systemIndigo
        case "show":
            typeText = " SHOW "
            badgeColor = .systemTeal
        default:
            typeText = " \(config.mediaType.uppercased()) "
            badgeColor = .systemGray
        }
        typeBadge.text = typeText
        typeBadge.backgroundColor = badgeColor

        posterImageView.image = nil
        placeholderView.isHidden = false

        guard let posterPath = config.posterPath else { return }

        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: posterPath, width: 185)
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.posterImageView.image = image
                self.placeholderView.isHidden = true
            }
        }
    }
}
