import UIKit

/// Floating glass pill that hosts the Library controls (section switcher, sort/filter, folder
/// browsing) just above the tab bar, keeping them thumb-reachable. Positioned relative to the
/// tab bar's frame rather than the safe area, because the floating tab bar overlays content
/// instead of reserving layout space.
@MainActor
final class LibraryActionBarView: UIView {
    static let height: CGFloat = 56
    private static let folderActionIdentifier = UIAction.Identifier("crucible.library.browseFolders")

    let switcherButton = UIButton(configuration: .plain())
    private let optionsButton = UIButton(configuration: .plain())
    private let folderButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        let glass = Glass.effectView(fallback: .systemMaterial, interactive: true)
        glass.layer.cornerRadius = 22
        glass.layer.cornerCurve = .continuous
        glass.layer.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        switcherButton.showsMenuAsPrimaryAction = true
        switcherButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        optionsButton.showsMenuAsPrimaryAction = true
        optionsButton.accessibilityLabel = "Sort and Filter"
        folderButton.accessibilityLabel = "Browse Folders"

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [switcherButton, spacer, optionsButton, folderButton])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 22, cornerHeight: 22, transform: nil)
    }

    func setSwitcher(title: String, menu: UIMenu) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(scale: .small))
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.baseForegroundColor = .label
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        switcherButton.configuration = config
        switcherButton.menu = menu
    }

    func setOptions(menu: UIMenu?, icon: UIImage?) {
        var config = UIButton.Configuration.plain()
        config.image = icon
        config.baseForegroundColor = .secondaryLabel
        optionsButton.configuration = config
        optionsButton.menu = menu
    }

    func setFolderAction(_ action: @escaping () -> Void) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "folder")
        config.baseForegroundColor = .secondaryLabel
        folderButton.configuration = config
        folderButton.removeAction(identifiedBy: Self.folderActionIdentifier, for: .touchUpInside)
        folderButton.addAction(UIAction(identifier: Self.folderActionIdentifier) { _ in action() }, for: .touchUpInside)
    }
}
