import CrucibleCore
import CrucibleDesign
import UIKit

/// One researched file in full: the poster, the file name becoming the title, the event, its card, the sites the facts
/// came from, what the research took, and for the owner, Research again.
final class SportsItemViewController: UIViewController {
    private let item: SportsItem
    private let canRedo: Bool
    private let onRedo: () -> Void
    private let stack = UIStackView()
    private var playedChange = false

    init(item: SportsItem, canRedo: Bool, onRedo: @escaping () -> Void) {
        self.item = item
        self.canRedo = canRedo
        self.onRedo = onRedo
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        title = item.detail?.event ?? SportsItemLabel.title(item)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "settings.sports.item"
        rebuild()
        stack.axis = .vertical
        stack.spacing = Theme.Space.l
        for view in [scroll, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
        ])
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) { (controller: SportsItemViewController, _: UITraitCollection) in
            controller.rebuild()
        }
    }

    /// Lays the sheet out for the width and text size it has now, which change with a split view or a text size change.
    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sections().forEach(stack.addArrangedSubview)
    }

    private func sections() -> [UIView] {
        var sections: [UIView] = [header()]
        if item.state == "attention" || item.state == "failed" {
            sections.append(note(item.note.isEmpty ? SportsCopy.attentionHelp : item.note, color: .systemOrange))
        } else if !item.note.isEmpty {
            sections.append(note(item.note, color: Theme.Color.labelSecondary))
        }
        if let detail = item.detail {
            if !detail.summary.isEmpty { sections.append(note(detail.summary, color: Theme.Color.label)) }
            var facts: [(String, String)] = [(SportsCopy.event, detail.event)]
            if let day = detail.day { facts.append((SportsCopy.date, SportsCopy.day(day))) }
            if !detail.place.isEmpty { facts.append((SportsCopy.venue, detail.place)) }
            sections.append(group(nil, rows: facts.map { fact($0.0, $0.1) }))
            if !detail.lineup.isEmpty {
                sections.append(group(detail.part.map { "\(SportsCopy.card) · \($0)" } ?? SportsCopy.card, rows: detail.lineup.map { bout($0) }))
            }
            if !detail.sources.isEmpty {
                sections.append(group(SportsCopy.sources, rows: detail.sources.map { fact(nil, $0, symbol: "globe") }))
            }
        }
        if item.measured { sections.append(group(SportsCopy.research, rows: [researchRow()])) }
        sections.append(group(SportsCopy.file, rows: [fact(nil, item.fileName, monospaced: true)]))
        if canRedo {
            var configuration = Glass.prominentButton { UIButton.Configuration.filled() }
            configuration.baseBackgroundColor = Theme.Color.accent
            configuration.baseForegroundColor = Theme.Color.onAccent
            configuration.title = SportsCopy.researchAgain
            configuration.image = UIImage(systemName: "arrow.clockwise")
            configuration.imagePadding = 8
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .large
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.confirmRedo() })
            button.accessibilityIdentifier = "settings.sports.item.redo"
            sections.append(button)
        }
        return sections
    }

    private func header() -> UIView {
        let poster = SportsPosterView()
        poster.translatesAutoresizingMaskIntoConstraints = false
        let width: CGFloat = 150
        NSLayoutConstraint.activate([
            poster.widthAnchor.constraint(equalToConstant: width),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: Theme.Size.posterAspect),
        ])
        poster.show(path: item.state == "matched" || item.state == "edited" ? item.posterPath : nil, width: width, words: item.posterWords)
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory || traitCollection.horizontalSizeClass == .compact
        let matched = item.state == "matched" || item.state == "edited"
        let transform = SportsTransformView()
        transform.show(file: item.fileName, title: SportsItemLabel.title(item), titleFont: Theme.Font.title2, centered: stacked)
        let fileOnly = UILabel()
        fileOnly.text = item.fileName
        fileOnly.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .semibold))
        fileOnly.adjustsFontForContentSizeCategory = true
        fileOnly.textColor = Theme.Color.label
        fileOnly.numberOfLines = 0
        fileOnly.lineBreakMode = .byCharWrapping
        fileOnly.textAlignment = stacked ? .center : .natural
        let chip = UILabel()
        chip.text = SportsCopy.itemState(item.state).uppercased(with: .current)
        chip.font = Theme.Font.badge
        chip.textColor = item.state == "matched" ? Theme.Color.statusOK : item.state == "edited" ? Theme.Color.labelSecondary : .systemOrange
        let text = UIStackView(arrangedSubviews: [chip, matched ? transform : fileOnly])
        text.axis = .vertical
        text.spacing = Theme.Space.xs
        let row = UIStackView(arrangedSubviews: [poster, text])
        row.axis = stacked ? .vertical : .horizontal
        row.alignment = stacked ? .center : .top
        row.spacing = Theme.Space.m
        if stacked { text.alignment = .center }
        if matched, !playedChange, !UIAccessibility.isReduceMotionEnabled {
            playedChange = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { transform.play() }
        }
        return row
    }

    private func researchRow() -> UIView {
        guard !item.reusedResearch else { return note(SportsCopy.reused, color: Theme.Color.labelSecondary) }
        let tiles = [(SportsCopy.time, SportsCopy.duration(item.seconds)), (SportsCopy.searches, "\(item.searches)"), (SportsCopy.pagesRead, "\(item.reads)")].map { title, value in
            let number = UILabel()
            number.text = value
            number.font = Theme.Font.title3
            number.adjustsFontForContentSizeCategory = true
            number.textColor = Theme.Color.label
            let caption = UILabel()
            caption.text = title
            caption.font = Theme.Font.caption1Regular
            caption.adjustsFontForContentSizeCategory = true
            caption.textColor = Theme.Color.labelSecondary
            caption.numberOfLines = 0
            let tile = UIStackView(arrangedSubviews: [number, caption])
            tile.axis = .vertical
            tile.spacing = 2
            tile.isAccessibilityElement = true
            tile.accessibilityLabel = "\(title), \(value)"
            return tile
        }
        let row = UIStackView(arrangedSubviews: tiles)
        row.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Space.m
        return row
    }

    private func group(_ title: String?, rows: [UIView]) -> UIView {
        let box = UIStackView()
        box.axis = .vertical
        box.spacing = Theme.Space.s
        box.backgroundColor = Theme.Color.surface
        box.layer.cornerRadius = Theme.Radius.m
        box.layer.cornerCurve = .continuous
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.s, leading: Theme.Space.m, bottom: Theme.Space.s, trailing: Theme.Space.m)
        rows.forEach(box.addArrangedSubview)
        guard let title else { return box }
        let heading = UILabel()
        heading.text = title.uppercased(with: .current)
        heading.font = Theme.Font.footnote
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = Theme.Color.labelSecondary
        heading.accessibilityTraits = .header
        let stack = UIStackView(arrangedSubviews: [heading, box])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xs
        return stack
    }

    private func fact(_ title: String?, _ value: String, symbol: String? = nil, monospaced: Bool = false) -> UIView {
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = monospaced ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular)) : Theme.Font.body
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.label
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = monospaced ? .byCharWrapping : .byWordWrapping
        var views: [UIView] = []
        if let symbol {
            let icon = UIImageView(image: UIImage(systemName: symbol))
            icon.tintColor = Theme.Color.labelTertiary
            icon.setContentHuggingPriority(.required, for: .horizontal)
            views.append(icon)
        }
        if let title {
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = Theme.Font.subheadline
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = Theme.Color.labelSecondary
            titleLabel.setContentHuggingPriority(.required, for: .horizontal)
            views.append(titleLabel)
            valueLabel.textAlignment = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .natural : .right
        }
        views.append(valueLabel)
        let row = UIStackView(arrangedSubviews: views)
        row.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory && title != nil ? .vertical : .horizontal
        row.alignment = symbol == nil ? .firstBaseline : .center
        row.spacing = Theme.Space.s
        row.isAccessibilityElement = true
        row.accessibilityLabel = [title, value].compactMap { $0 }.joined(separator: ", ")
        return row
    }

    private func bout(_ bout: SportsEventDetail.Bout) -> UIView {
        let matchup = UILabel()
        matchup.text = bout.matchup
        matchup.font = Theme.Font.subheadlineSemibold
        matchup.adjustsFontForContentSizeCategory = true
        matchup.textColor = Theme.Color.label
        matchup.numberOfLines = 0
        let detail = UILabel()
        detail.text = bout.detail
        detail.font = Theme.Font.footnote
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.labelSecondary
        detail.isHidden = bout.detail.isEmpty
        let stack = UIStackView(arrangedSubviews: [matchup, detail])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = [bout.matchup, bout.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        return stack
    }

    private func note(_ text: String, color: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.callout
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func confirmRedo() {
        let alert = UIAlertController(title: SportsCopy.researchAgain, message: SportsCopy.redoQuestion, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: SportsCopy.researchAgain, style: .default) { [weak self] _ in
            self?.onRedo()
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
}
