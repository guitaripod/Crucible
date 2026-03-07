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

    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let durationLabel = UILabel()
    private let statusImageView = UIImageView()
    private let progressBar = ProgressBar()

    init(configuration: EpisodeContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.numberOfLines = 2

        durationLabel.font = .systemFont(ofSize: 13)
        durationLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, durationLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        statusImageView.contentMode = .scaleAspectFit
        statusImageView.tintColor = .systemGreen
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let trailingStack = UIStackView(arrangedSubviews: [statusImageView, progressBar])
        trailingStack.axis = .vertical
        trailingStack.alignment = .center
        trailingStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [numberLabel, textStack, trailingStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
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
        } else if let progress = config.progress, progress > 0 {
            statusImageView.isHidden = true
            progressBar.isHidden = false
            progressBar.progress = progress
        } else {
            statusImageView.isHidden = true
            progressBar.isHidden = true
        }
    }
}
