import CrucibleCore
import CrucibleDesign
import UIKit

/// One pick of What to Watch: the poster, the title, what the library knows of it, and the model's sentence on why
/// it fits what was asked.
struct WatchPickConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var title: String = ""
    var facts: String = ""
    var why: String = ""
    var placeholderIcon: String = "film"

    func makeContentView() -> UIView & UIContentView {
        WatchPickContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> WatchPickConfiguration {
        self
    }
}

final class WatchPickContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static let posterWidth: CGFloat = 68

    private let posterView = UIImageView()
    private let placeholderView = UIImageView()
    private let titleLabel = UILabel()
    private let factsLabel = UILabel()
    private let whyLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var shownPosterPath: String? = "__unset__"

    init(configuration: WatchPickConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.layer.cornerRadius = Theme.Radius.s
        posterView.layer.cornerCurve = .continuous
        posterView.layer.borderWidth = 1
        posterView.layer.borderColor = Theme.Color.artHairline.cgColor
        posterView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .light)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        posterView.addSubview(placeholderView)

        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true

        factsLabel.font = Theme.Font.footnote
        factsLabel.textColor = Theme.Color.labelSecondary
        factsLabel.numberOfLines = 1
        factsLabel.adjustsFontForContentSizeCategory = true

        whyLabel.font = Theme.Font.subheadline
        whyLabel.textColor = Theme.Color.label
        whyLabel.numberOfLines = 0
        whyLabel.adjustsFontForContentSizeCategory = true

        let text = UIStackView(arrangedSubviews: [titleLabel, factsLabel, whyLabel])
        text.axis = .vertical
        text.spacing = 2
        text.setCustomSpacing(Theme.Space.xs, after: factsLabel)

        let row = UIStackView(arrangedSubviews: [posterView, text])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.s)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.s),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.l),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            bottom,
            posterView.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            posterView.heightAnchor.constraint(equalTo: posterView.widthAnchor, multiplier: Theme.Size.posterAspect),
            placeholderView.centerXAnchor.constraint(equalTo: posterView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: posterView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func apply() {
        guard let configuration = configuration as? WatchPickConfiguration else { return }
        titleLabel.text = configuration.title
        factsLabel.text = configuration.facts
        factsLabel.isHidden = configuration.facts.isEmpty
        whyLabel.text = configuration.why
        placeholderView.image = UIImage(systemName: configuration.placeholderIcon)
        accessibilityLabel = [configuration.title, configuration.facts, configuration.why].filter { !$0.isEmpty }.joined(separator: ", ")
        loadPoster(configuration.posterPath)
    }

    private func loadPoster(_ path: String?) {
        guard path != shownPosterPath else { return }
        shownPosterPath = path
        imageTask?.cancel()
        posterView.image = nil
        placeholderView.isHidden = false
        guard let path else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: Int(Self.posterWidth * 3))
            guard !Task.isCancelled, let self, self.shownPosterPath == path, let image else { return }
            self.posterView.image = image
            self.placeholderView.isHidden = true
        }
    }
}
