import UIKit

struct SectionHeaderConfiguration: UIContentConfiguration, Hashable {
    var title: String = ""
    var actionTitle: String?
    var onAction: (() -> Void)?

    static func == (lhs: SectionHeaderConfiguration, rhs: SectionHeaderConfiguration) -> Bool {
        lhs.title == rhs.title && lhs.actionTitle == rhs.actionTitle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(actionTitle)
    }

    func makeContentView() -> UIView & UIContentView {
        SectionHeaderContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SectionHeaderConfiguration {
        self
    }
}

final class SectionHeaderContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let titleLabel = UILabel()
    private let actionButton = UIButton(configuration: .plain())
    private var onAction: (() -> Void)?

    init(configuration: SectionHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        titleLabel.font = Theme.Font.title3
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, actionButton])
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? SectionHeaderConfiguration else { return }
        titleLabel.text = config.title
        onAction = config.onAction

        guard let actionTitle = config.actionTitle else {
            actionButton.isHidden = true
            return
        }
        actionButton.isHidden = false
        var button = UIButton.Configuration.plain()
        button.title = actionTitle
        button.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        button.imagePlacement = .trailing
        button.imagePadding = 3
        button.baseForegroundColor = Theme.Color.accentText
        button.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadline
            return outgoing
        }
        actionButton.configuration = button
        actionButton.accessibilityLabel = "\(actionTitle) \(config.title)"
    }
}
