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

    private static let avatarSize = Theme.Size.castAvatar
    private static let palettes: [(UInt32, UInt32)] = [
        (0x2B2455, 0xB0483F),
        (0x0F3D3E, 0x1D7A73),
        (0x3A1A52, 0x8B2F7A),
        (0x101A33, 0x1F3F7A),
        (0x26402C, 0x4F7A45),
        (0x6B2A3A, 0x7E3346),
    ]

    private let avatar = UIView()
    private let gradient = CAGradientLayer()
    private let initialsLabel = UILabel()
    private let photoView = UIImageView()
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
        let size = Self.avatarSize
        avatar.layer.cornerRadius = size / 2
        avatar.layer.borderWidth = 1
        avatar.layer.borderColor = Theme.Color.artHairline.cgColor
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        avatar.layer.addSublayer(gradient)

        initialsLabel.font = Theme.Font.scaled(.title2, 22, .bold, maximum: 26)
        initialsLabel.textColor = Theme.Color.onArt.withAlphaComponent(0.92)
        initialsLabel.textAlignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.translatesAutoresizingMaskIntoConstraints = false

        avatar.addSubview(initialsLabel)
        avatar.addSubview(photoView)

        nameLabel.font = Theme.Font.caption1
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center

        roleLabel.font = Theme.Font.caption2Regular
        roleLabel.adjustsFontForContentSizeCategory = true
        roleLabel.textColor = Theme.Color.labelSecondary
        roleLabel.numberOfLines = 2
        roleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [avatar, nameLabel, roleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        stack.setCustomSpacing(6, after: avatar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: size),
            avatar.heightAnchor.constraint(equalToConstant: size),
            initialsLabel.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            initialsLabel.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            photoView.topAnchor.constraint(equalTo: avatar.topAnchor),
            photoView.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            photoView.bottomAnchor.constraint(equalTo: avatar.bottomAnchor),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            roleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        isAccessibilityElement = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = avatar.bounds
        CATransaction.commit()
    }

    private func apply() {
        guard let config = configuration as? CastContentConfiguration else { return }
        nameLabel.text = config.name
        roleLabel.text = config.role
        roleLabel.isHidden = (config.role ?? "").isEmpty
        initialsLabel.text = DetailFormat.initials(config.name)
        let palette = Self.palettes[Self.stableIndex(config.name, count: Self.palettes.count)]
        gradient.colors = [UIColor(hex: palette.0).cgColor, UIColor(hex: palette.1).cgColor]
        accessibilityLabel = [config.name, config.role].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        loadThumb(config.thumbPath)
    }

    /// Deterministic across launches (unlike `hashValue`), so a person keeps their colour.
    private static func stableIndex(_ name: String, count: Int) -> Int {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return sum % count
    }

    private func loadThumb(_ path: String?) {
        guard path != currentPath else { return }
        imageTask?.cancel()
        imageTask = nil
        currentPath = path
        photoView.image = nil
        photoView.isHidden = true
        guard let path, !path.isEmpty else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: Int(Self.avatarSize * 3))
            guard !Task.isCancelled, let self, let image else { return }
            self.photoView.image = image
            self.photoView.isHidden = false
        }
    }
}
