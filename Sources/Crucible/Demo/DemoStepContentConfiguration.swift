import CrucibleCore
import CrucibleDesign
import UIKit

/// A tour step in the tour list: a check that fills in when it is done, the step's name and what it shows, and a "Show me" pill. The
/// whole row is the control; the pill only says so.
struct DemoStepContentConfiguration: UIContentConfiguration {
    var row: DemoPhoneTourRow

    func makeContentView() -> UIView & UIContentView {
        DemoStepContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DemoStepContentConfiguration {
        self
    }
}

final class DemoStepContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let checkView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let pill = UIView()
    private let pillLabel = UILabel()
    private let rootStack = UIStackView()
    private let topRow = UIStackView()
    private let stackedRow = UIStackView(arrangedSubviews: [UIView()])

    init(configuration: DemoStepContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        build()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: DemoStepContentView, _: UITraitCollection) in
            view.placePill()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

        checkView.contentMode = .center
        checkView.setContentHuggingPriority(.required, for: .horizontal)
        checkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        checkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 28).isActive = true

        titleLabel.font = Theme.Font.callout
        titleLabel.textColor = Theme.Color.label
        detailLabel.font = Theme.Font.caption1Regular
        detailLabel.textColor = Theme.Color.labelSecondary
        for label in [titleLabel, detailLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2

        pillLabel.text = DemoPhoneCopy.showMe
        pillLabel.font = Theme.Font.footnoteSemibold
        pillLabel.adjustsFontForContentSizeCategory = true
        pillLabel.setContentHuggingPriority(.required, for: .horizontal)
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = 14
        pill.layer.cornerCurve = .continuous
        pill.addSubview(pillLabel)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            pillLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
        ])

        topRow.axis = .horizontal
        topRow.spacing = 12
        topRow.alignment = .center
        topRow.addArrangedSubview(checkView)
        topRow.addArrangedSubview(text)

        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.alignment = .fill
        stackedRow.axis = .horizontal
        rootStack.addArrangedSubview(topRow)
        rootStack.addArrangedSubview(stackedRow)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        placePill()
    }

    /// The pill sits at the row's trailing edge; at the largest text sizes it drops under the text so the words keep their width.
    private func placePill() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        pill.removeFromSuperview()
        topRow.alignment = stacked ? .top : .center
        stackedRow.isHidden = !stacked
        if stacked {
            stackedRow.insertArrangedSubview(pill, at: 0)
        } else {
            topRow.addArrangedSubview(pill)
        }
    }

    private func apply() {
        guard let config = configuration as? DemoStepContentConfiguration else { return }
        let row = config.row
        titleLabel.text = row.step.title
        detailLabel.text = row.step.detail
        let symbol = row.isDone ? "checkmark.circle.fill" : "circle"
        checkView.image = UIImage(systemName: symbol)
        checkView.tintColor = row.isDone ? Theme.Color.statusOK : Theme.Color.labelTertiary
        pill.backgroundColor = row.isNext ? Theme.Color.accent : Theme.Color.surfaceRaised
        pillLabel.textColor = row.isNext ? Theme.Color.onAccent : Theme.Color.label
    }
}
