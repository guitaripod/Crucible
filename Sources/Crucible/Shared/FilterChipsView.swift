import UIKit

/// A horizontally scrolling row of capsule chips. A chip either toggles a filter (`onSelect`) or opens
/// a menu; the selected style is the ember tint used everywhere an option is "on".
@MainActor
final class FilterChipsView: UIView {
    struct Chip {
        let id: String
        let title: String
        var isSelected: Bool = false
        var menu: UIMenu?
    }

    static let height: CGFloat = 34

    var onSelect: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Theme.Space.m, bottom: 0, right: Theme.Space.m)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = Theme.Space.xs
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setChips(_ chips: [Chip]) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for chip in chips {
            stack.addArrangedSubview(makeButton(for: chip))
        }
    }

    private func makeButton(for chip: Chip) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = chip.title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.background.backgroundColor = chip.isSelected ? Theme.Color.accentTint : Theme.Color.surfaceRaised
        config.background.strokeColor = chip.isSelected ? Theme.Color.accentText : Theme.Color.separator
        config.background.strokeWidth = 1
        config.baseForegroundColor = chip.isSelected ? Theme.Color.accentText : Theme.Color.label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.subheadline, 14, .semibold, maximum: 20)
            return outgoing
        }
        if chip.menu != nil {
            config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
            config.imagePlacement = .trailing
            config.imagePadding = 6
        }

        let button = UIButton(configuration: config)
        button.accessibilityTraits = chip.isSelected ? [.button, .selected] : .button
        if let menu = chip.menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        } else {
            let id = chip.id
            button.addAction(UIAction { [weak self] _ in
                Haptics.selection()
                self?.onSelect?(id)
            }, for: .primaryActionTriggered)
        }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height).isActive = true
        return button
    }
}
