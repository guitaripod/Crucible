import CrucibleDesign
import UIKit

/// A button of the action row (Play, Start Over, Mark Watched, Audio, Subtitles ...). The button is
/// a real `UIButton`, so it gets the system focus and press behaviour; the cell is not focusable.
final class TVDetailActionCell: UICollectionViewCell {
    private let button = UIButton(type: .system)
    private var actionIdentifier: UIAction.Identifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [button] }

    static func registration(
        actions: @escaping @MainActor (TVDetailAction.Kind) -> TVDetailAction?
    ) -> UICollectionView.CellRegistration<TVDetailActionCell, TVDetailAction.Kind> {
        UICollectionView.CellRegistration<TVDetailActionCell, TVDetailAction.Kind> { cell, _, kind in
            guard let action = actions(kind) else { return }
            cell.configure(with: action)
        }
    }

    func configure(with action: TVDetailAction) {
        if let menu = action.menu {
            configureMenu(action, menu: menu)
        } else {
            configureButton(action)
        }
        button.isEnabled = action.isEnabled
        button.accessibilityLabel = action.accessibilityLabel ?? action.title
        button.accessibilityIdentifier = "detail.action.\(action.kind.rawValue)"
    }

    private func configureButton(_ action: TVDetailAction) {
        let style: TVButton.Style = action.appearance == .primary ? .primary : .glass
        button.configuration = TVButton.configuration(style, title: action.title, symbol: action.symbol)
        button.menu = nil
        button.showsMenuAsPrimaryAction = false
        if let identifier = actionIdentifier {
            button.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
        }
        let handler = action.handler
        let primary = UIAction { _ in handler() }
        actionIdentifier = primary.identifier
        button.addAction(primary, for: .primaryActionTriggered)
    }

    private func configureMenu(_ action: TVDetailAction, menu: UIMenu) {
        if let identifier = actionIdentifier {
            button.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
            actionIdentifier = nil
        }
        var configuration = TVButton.configuration(.glass, title: action.title, symbol: nil)
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            font: Theme.Font.scaled(.callout, 31, .semibold, maximum: 44),
            scale: .small
        )
        button.configuration = configuration
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
    }
}
