import CrucibleCore
import CrucibleDesign
import UIKit

/// One researched file in the results grid: its poster, its new title (or its file name while it needs a look), when
/// and where the event was, and above the title where it stands unless it simply matched.
struct SportsResultConfiguration: UIContentConfiguration {
    var item: SportsItem
    var highlighted = false

    func makeContentView() -> UIView & UIContentView { SportsResultView(configuration: self) }

    func updated(for state: UIConfigurationState) -> SportsResultConfiguration {
        var updated = self
        updated.highlighted = (state as? UICellConfigurationState)?.isHighlighted == true
        return updated
    }
}

final class SportsResultView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let poster = SportsPosterView()
    private let stateLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let stack = UIStackView()
    private lazy var posterWidth = poster.widthAnchor.constraint(equalToConstant: 110)

    init(configuration: SportsResultConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        stateLabel.font = Theme.Font.badge
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.numberOfLines = 1
        titleLabel.font = Theme.Font.subheadlineSemibold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 3
        metaLabel.font = Theme.Font.footnote
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [stateLabel, titleLabel, metaLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs
        stack.addArrangedSubview(poster)
        stack.addArrangedSubview(text)
        stack.spacing = Theme.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: Theme.Size.posterAspect),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        arrange()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in self.arrange() }
        apply()
    }

    /// A poster above its words in the grid; at the largest text sizes, where the grid is one column, a small poster beside
    /// them, so a result does not fill the screen.
    private func arrange() {
        let beside = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stack.axis = beside ? .horizontal : .vertical
        stack.alignment = beside ? .top : .fill
        stack.spacing = beside ? Theme.Space.m : Theme.Space.xs
        posterWidth.isActive = beside
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let configuration = configuration as? SportsResultConfiguration else { return }
        poster.show(path: configuration.item.showsArtwork ? configuration.item.posterPath : nil, width: max(poster.bounds.width, 60), words: configuration.item.posterWords, kind: configuration.item.kind)
    }

    private func apply() {
        guard let configuration = configuration as? SportsResultConfiguration else { return }
        let item = configuration.item
        let matched = item.state == "matched" || item.state == "edited"
        titleLabel.text = SportsItemLabel.title(item)
        titleLabel.font = matched ? Theme.Font.subheadlineSemibold : Theme.Font.scaled(.footnote, .monospacedSystemFont(ofSize: 12, weight: .medium))
        titleLabel.lineBreakMode = matched ? .byTruncatingTail : .byTruncatingMiddle
        metaLabel.text = SportsCopy.meta(item)
        metaLabel.isHidden = metaLabel.text?.isEmpty ?? true
        let attention = item.state == "attention" || item.state == "failed"
        stateLabel.text = SportsCopy.itemState(item.state).uppercased(with: .current)
        stateLabel.textColor = attention ? .systemOrange : Theme.Color.labelSecondary
        stateLabel.isHidden = item.state == "matched"
        if poster.bounds.width > 0 { poster.show(path: item.showsArtwork ? item.posterPath : nil, width: poster.bounds.width, words: item.posterWords, kind: item.kind) }
        alpha = configuration.highlighted && !UIAccessibility.isReduceMotionEnabled ? 0.7 : 1
        accessibilityLabel = matched ? SportsCopy.becomes(item.fileName, SportsItemLabel.title(item)) : item.fileName
        accessibilityValue = [SportsCopy.itemState(item.state), metaLabel.text].compactMap { $0 }.joined(separator: ", ")
    }
}
