import UIKit

struct CastContentConfiguration: UIContentConfiguration, Hashable {
    var thumbPath: String?
    var name: String = ""
    var role: String?

    func makeContentView() -> UIView & UIContentView {
        CastContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> CastContentConfiguration {
        self
    }
}

final class CastContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let thumbView = UIImageView()
    private let placeholder = UIImageView()
    private let nameLabel = UILabel()
    private let roleLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var currentPath: String? = "__unset__"

    init(configuration: CastContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = .secondarySystemBackground
        thumbView.layer.cornerRadius = 40
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.image = UIImage(systemName: "person.fill")
        placeholder.tintColor = .quaternaryLabel
        placeholder.contentMode = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center

        roleLabel.font = .systemFont(ofSize: 11)
        roleLabel.textColor = .secondaryLabel
        roleLabel.numberOfLines = 1
        roleLabel.textAlignment = .center

        thumbView.addSubview(placeholder)

        let stack = UIStackView(arrangedSubviews: [thumbView, nameLabel, roleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            thumbView.widthAnchor.constraint(equalToConstant: 80),
            thumbView.heightAnchor.constraint(equalToConstant: 80),
            placeholder.centerXAnchor.constraint(equalTo: thumbView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: thumbView.centerYAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func apply() {
        guard let config = configuration as? CastContentConfiguration else { return }
        nameLabel.text = config.name
        roleLabel.text = config.role
        roleLabel.isHidden = (config.role ?? "").isEmpty
        loadThumb(config.thumbPath)
    }

    private func loadThumb(_ path: String?) {
        guard path != currentPath else { return }
        imageTask?.cancel()
        imageTask = nil
        currentPath = path
        thumbView.image = nil
        placeholder.isHidden = false
        guard let path, !path.isEmpty else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: 160)
            guard !Task.isCancelled, let self else { return }
            if let image {
                self.thumbView.image = image
                self.placeholder.isHidden = true
            }
        }
    }
}
