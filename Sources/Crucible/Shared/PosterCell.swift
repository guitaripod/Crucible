@preconcurrency import UIKit

struct PosterContentConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var title: String = ""
    var subtitle: String?
    var progress: Double?
    var placeholderIcon: String = "film"
    var showPlayButton: Bool = false
    var onQuickPlay: (() -> Void)?

    static func == (lhs: PosterContentConfiguration, rhs: PosterContentConfiguration) -> Bool {
        lhs.posterPath == rhs.posterPath && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.progress == rhs.progress && lhs.showPlayButton == rhs.showPlayButton
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(posterPath)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(showPlayButton)
    }

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

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressBar = ProgressBar()
    private let placeholderView = UIImageView()
    private let quickPlayButton = UIButton()
    private var imageTask: Task<Void, Never>?
    private var onQuickPlay: (() -> Void)?
    private var currentPosterPath: String?

    init(configuration: PosterContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        cardView.layer.cornerRadius = 12
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        cardView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        cardView.translatesAutoresizingMaskIntoConstraints = false

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 6

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.3).cgColor,
            UIColor.black.withAlphaComponent(0.8).cgColor,
        ]
        gradientLayer.locations = [0.35, 0.65, 1.0]
        imageView.layer.addSublayer(gradientLayer)

        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        placeholderView.tintColor = .quaternaryLabel
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        let playConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        quickPlayButton.setImage(UIImage(systemName: "play.fill", withConfiguration: playConfig), for: .normal)
        quickPlayButton.tintColor = .white
        quickPlayButton.backgroundColor = UIColor.systemOrange
        quickPlayButton.layer.cornerRadius = 14
        quickPlayButton.layer.cornerCurve = .continuous
        quickPlayButton.translatesAutoresizingMaskIntoConstraints = false
        quickPlayButton.isHidden = true
        quickPlayButton.addAction(UIAction { [unowned self] _ in
            self.onQuickPlay?()
        }, for: .touchUpInside)

        addSubview(cardView)
        cardView.addSubview(imageView)
        cardView.addSubview(placeholderView)
        cardView.addSubview(textStack)
        cardView.addSubview(progressBar)
        cardView.addSubview(quickPlayButton)

        let heightConstraint = cardView.heightAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: 3.0 / 2.0)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor, constant: -12),
            placeholderView.widthAnchor.constraint(equalToConstant: 32),
            placeholderView.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            quickPlayButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -6),
            quickPlayButton.bottomAnchor.constraint(equalTo: textStack.topAnchor, constant: -6),
            quickPlayButton.widthAnchor.constraint(equalToConstant: 28),
            quickPlayButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = imageView.bounds
    }

    private func apply() {
        guard let config = configuration as? PosterContentConfiguration else { return }
        onQuickPlay = config.onQuickPlay
        quickPlayButton.isHidden = !config.showPlayButton

        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = config.subtitle == nil

        if let progress = config.progress, progress > 0 {
            progressBar.isHidden = false
            progressBar.progress = progress
        } else {
            progressBar.isHidden = true
        }

        if config.posterPath != currentPosterPath {
            currentPosterPath = config.posterPath
            imageView.image = nil
            placeholderView.isHidden = false
            placeholderView.image = UIImage(systemName: config.placeholderIcon)

            if let posterPath = config.posterPath {
                imageTask = Task { [weak self] in
                    let image = await ImageLoader.shared.loadImage(path: posterPath, width: 300)
                    guard !Task.isCancelled, let self else { return }
                    if let image {
                        UIView.transition(with: self.imageView, duration: 0.2, options: .transitionCrossDissolve) {
                            self.imageView.image = image
                        }
                        self.placeholderView.isHidden = true
                    }
                }
            }
        }
    }
}
