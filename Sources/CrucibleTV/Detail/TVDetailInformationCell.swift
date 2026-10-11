import CrucibleCore
import CrucibleDesign
import UIKit

/// The Information panel: a two-column grid of facts (studio, directors, dates, file, audio). It is
/// one focusable surface, so the remote can scroll down to it and it lifts like every other panel.
final class TVInformationSurface: TVFocusableSurface {
    private let grid = UIStackView()

    init() {
        super.init(cornerRadius: Theme.Radius.m)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "detail.information"
        grid.axis = .vertical
        grid.spacing = Theme.Space.m
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(facts: [DetailFact]) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for start in stride(from: 0, to: facts.count, by: 2) {
            let pair = facts[start ..< min(start + 2, facts.count)]
            let row = UIStackView(arrangedSubviews: pair.map(Self.factView))
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Theme.Space.l
            if pair.count == 1 { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
        accessibilityLabel = "Information, " + facts.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private static func factView(_ fact: DetailFact) -> UIView {
        let key = UILabel()
        key.font = Theme.Font.caption1
        key.textColor = Theme.Color.labelTertiary
        key.text = fact.key.uppercased()
        let value = UILabel()
        value.font = Theme.Font.body
        value.textColor = Theme.Color.label
        value.numberOfLines = 2
        value.text = fact.value
        let stack = UIStackView(arrangedSubviews: [key, value])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xxs
        return stack
    }
}

final class TVDetailInformationCell: UICollectionViewCell {
    private let surface = TVInformationSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TVMetrics.shelfTopInset),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -TVMetrics.shelfBottomInset),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [surface] }

    static func registration(
        facts: @escaping @MainActor () -> [DetailFact]
    ) -> UICollectionView.CellRegistration<TVDetailInformationCell, Int> {
        UICollectionView.CellRegistration<TVDetailInformationCell, Int> { cell, _, _ in
            cell.surface.configure(facts: facts())
        }
    }
}
