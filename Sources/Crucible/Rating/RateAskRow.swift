import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// One title in Rate What You Watched: its poster, why it is asked about, and five stars that rate it in place.
struct RateAskRowConfiguration: UIContentConfiguration {
    var ask: RatingAsk
    var rating: UserRating?
    var onRate: (UserRating) -> Void

    func makeContentView() -> UIView & UIContentView { RateAskRowContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> RateAskRowConfiguration { self }
}

final class RateAskRowContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration { didSet { apply() } }

    private static let posterWidth: CGFloat = 60

    private let posterView = UIImageView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let stars = StarRatingControl(starSize: 30, starSpacing: 6)
    private let ratedMark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private var onRate: (UserRating) -> Void = { _ in }
    private var imageTask: Task<Void, Never>?
    private var loadedPoster: String?

    init(configuration: RateAskRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.tintColor = Theme.Color.labelTertiary
        posterView.layer.cornerRadius = 8
        posterView.layer.cornerCurve = .continuous
        posterView.layer.borderWidth = 1
        posterView.layer.borderColor = Theme.Color.artHairline.cgColor
        posterView.isAccessibilityElement = false
        posterView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            posterView.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: Self.posterWidth * Theme.Size.posterAspect),
        ])

        titleLabel.font = Theme.Font.scaled(.callout, 16, .semibold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        captionLabel.font = Theme.Font.footnote
        captionLabel.textColor = Theme.Color.labelSecondary
        captionLabel.numberOfLines = 2
        for label in [titleLabel, captionLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        stars.addAction(UIAction { [weak self] _ in self?.commit() }, for: .primaryActionTriggered)
        ratedMark.tintColor = Theme.Color.accent
        ratedMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        ratedMark.setContentHuggingPriority(.required, for: .horizontal)
        ratedMark.isAccessibilityElement = false

        let starRow = UIStackView(arrangedSubviews: [stars, ratedMark, UIView()])
        starRow.spacing = Theme.Space.s
        starRow.alignment = .center

        let texts = UIStackView(arrangedSubviews: [titleLabel, captionLabel, starRow])
        texts.axis = .vertical
        texts.spacing = 2
        texts.setCustomSpacing(Theme.Space.xs, after: captionLabel)

        let root = UIStackView(arrangedSubviews: [posterView, texts])
        root.spacing = 14
        root.alignment = .center
        root.pin(to: self, insets: NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))

        accessibilityElements = [titleLabel, captionLabel, stars]
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func apply() {
        guard let config = configuration as? RateAskRowConfiguration else { return }
        titleLabel.text = config.ask.title
        captionLabel.text = config.ask.caption(now: Date())
        onRate = config.onRate
        stars.setRating(config.rating, animated: window != nil)
        stars.accessibilityLabel = RatingAskCopy.question(for: config.ask)
        stars.accessibilityIdentifier = "rateWatched.stars.\(config.ask.ratingKey)"
        ratedMark.isHidden = config.rating == nil
        loadPoster(path: config.ask.posterPath, isShow: config.ask.isShow)
    }

    private func commit() {
        guard let rating = stars.rating else { return }
        ratedMark.isHidden = false
        onRate(rating)
    }

    /// The poster once it loads, a film or TV symbol until then and when the title has none.
    private func loadPoster(path: String?, isShow: Bool) {
        let key = "\(isShow)|\(path ?? "")"
        guard key != loadedPoster else { return }
        loadedPoster = key
        imageTask?.cancel()
        posterView.contentMode = .center
        posterView.image = UIImage(systemName: isShow ? "tv" : "film")
        guard let path else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: Int(Self.posterWidth * 3))
            guard !Task.isCancelled, let self, loadedPoster == key, let image else { return }
            posterView.contentMode = .scaleAspectFill
            posterView.image = image
        }
    }
}
