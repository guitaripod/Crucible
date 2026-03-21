import UIKit

struct EpisodeContentConfiguration: UIContentConfiguration, Hashable {
    var episodeNumber: Int?
    var title: String = ""
    var duration: String?
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

    private let numberContainer = UIView()
    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let durationLabel = UILabel()
    private let statusImageView = UIImageView()
    private let progressBar = ProgressBar()

    init(configuration: EpisodeContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        numberContainer.backgroundColor = .secondarySystemBackground
        numberContainer.layer.cornerRadius = 6
        numberContainer.layer.cornerCurve = .continuous
        numberContainer.translatesAutoresizingMaskIntoConstraints = false

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 2

        durationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .tertiaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, durationLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        statusImageView.contentMode = .scaleAspectFit
        statusImageView.tintColor = .systemOrange
        statusImageView.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let trailingStack = UIStackView(arrangedSubviews: [statusImageView, progressBar])
        trailingStack.axis = .vertical
        trailingStack.alignment = .center
        trailingStack.spacing = 2

        numberContainer.addSubview(numberLabel)

        let mainStack = UIStackView(arrangedSubviews: [numberContainer, textStack, trailingStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            numberContainer.widthAnchor.constraint(equalToConstant: 36),
            numberContainer.heightAnchor.constraint(equalToConstant: 36),
            numberLabel.centerXAnchor.constraint(equalTo: numberContainer.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: numberContainer.centerYAnchor),

            statusImageView.widthAnchor.constraint(equalToConstant: 24),
            statusImageView.heightAnchor.constraint(equalToConstant: 24),
            progressBar.widthAnchor.constraint(equalToConstant: 44),

            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? EpisodeContentConfiguration else { return }
        numberLabel.text = config.episodeNumber.map { "\($0)" } ?? "—"
        titleLabel.text = config.title
        durationLabel.text = config.duration
        durationLabel.isHidden = config.duration == nil

        if config.isWatched {
            statusImageView.image = UIImage(systemName: "checkmark.circle.fill")
            statusImageView.isHidden = false
            progressBar.isHidden = true
            numberContainer.backgroundColor = .systemOrange.withAlphaComponent(0.15)
            numberLabel.textColor = .systemOrange
        } else if let progress = config.progress, progress > 0 {
            statusImageView.isHidden = true
            progressBar.isHidden = false
            progressBar.progress = progress
            numberContainer.backgroundColor = .secondarySystemBackground
            numberLabel.textColor = .secondaryLabel
        } else {
            statusImageView.isHidden = true
            progressBar.isHidden = true
            numberContainer.backgroundColor = .secondarySystemBackground
            numberLabel.textColor = .secondaryLabel
        }
    }
}
