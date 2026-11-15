import CrucibleCore
import CrucibleDesign
import UIKit

/// What a setup step card can do for the owner, wired by the screen.
struct SportsStepActions {
    var toggle: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var share: (String, UIView) -> Void = { _, _ in }
    var agree: () -> Void = {}
    var library: (SportsLibrary) -> Void = { _ in }
    var switchOn: () -> Void = {}
}

/// One of the four setup steps: its number, what it asks, and when open, each check with why it matters and the exact
/// thing to do, a command to copy or share, or the button that settles it here.
struct SportsStepConfiguration: UIContentConfiguration {
    var step: SportsSetupStep
    var total: Int
    var expanded: Bool
    var owner: Bool
    var settings: SportsSettings
    var libraries: [SportsLibrary]
    var busy: Bool
    var actions: SportsStepActions

    func makeContentView() -> UIView & UIContentView { SportsStepView(configuration: self) }
    func updated(for state: UIConfigurationState) -> SportsStepConfiguration { self }

    /// What the open step's body is built from, so a poll that changes none of it leaves the body, its focus and a touch
    /// in progress alone.
    fileprivate var body: [AnyHashable] {
        [step, total, expanded, owner, settings.on, settings.agreed, settings.destination, libraries, busy]
    }
}

final class SportsStepView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let card = UIView()
    private let badge = UIView()
    private let badgeLabel = UILabel()
    private let badgeIcon = UIImageView()
    private let numberLabel = UILabel()
    private let titleLabel = UILabel()
    private let stateLabel = UILabel()
    private let chevron = UIImageView()
    private let header = UIControl()
    private let body = UIStackView()

    private var builtBody: [AnyHashable]?

    init(configuration: SportsStepConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in self.apply() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        badge.layer.cornerRadius = 15
        badge.layer.borderWidth = 2
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = Theme.Font.footnoteSemibold
        badgeLabel.textAlignment = .center
        badgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        badgeIcon.tintColor = .white
        for view in [badgeLabel, badgeIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(view)
        }
        numberLabel.font = Theme.Font.caption1
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = Theme.Color.labelSecondary
        titleLabel.font = Theme.Font.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        stateLabel.font = Theme.Font.footnote
        stateLabel.adjustsFontForContentSizeCategory = true
        stateLabel.textColor = Theme.Color.labelSecondary
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        chevron.tintColor = Theme.Color.labelTertiary
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let titles = UIStackView(arrangedSubviews: [numberLabel, titleLabel])
        titles.axis = .vertical
        titles.spacing = 2
        titles.isUserInteractionEnabled = false
        let headerRow = UIStackView(arrangedSubviews: [badge, titles, stateLabel, chevron])
        headerRow.alignment = .center
        headerRow.spacing = Theme.Space.s
        headerRow.isUserInteractionEnabled = false
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        header.addAction(UIAction { [weak self] _ in (self?.configuration as? SportsStepConfiguration)?.actions.toggle() }, for: .touchUpInside)
        header.isAccessibilityElement = true
        header.accessibilityTraits = [.button, .header]
        body.axis = .vertical
        body.spacing = Theme.Space.s
        let stack = UIStackView(arrangedSubviews: [header, body])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        for view in [card, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(card)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.s),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.s),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.m),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: Theme.Space.xxs),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -Theme.Space.xxs),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

    private func apply() {
        guard let configuration = configuration as? SportsStepConfiguration else { return }
        let step = configuration.step
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let number = SportsCopy.stepOf(step.number, configuration.total)
        numberLabel.text = (large ? "\(number) · \(SportsCopy.state(step.state))" : number).uppercased(with: .current)
        numberLabel.numberOfLines = large ? 0 : 1
        titleLabel.text = SportsCopy.groupTitle(step.group)
        let done = step.state == .done
        stateLabel.text = SportsCopy.state(step.state)
        stateLabel.isHidden = large
        stateLabel.textColor = step.state == .failed ? .systemOrange : Theme.Color.labelSecondary
        badgeLabel.text = "\(step.number)"
        badgeLabel.isHidden = done
        badgeIcon.image = UIImage(systemName: "checkmark")
        badgeIcon.isHidden = !done
        badge.backgroundColor = done ? Theme.Color.statusOK : .clear
        badge.layer.borderColor = (done ? Theme.Color.statusOK : step.state == .failed ? UIColor.systemOrange : Theme.Color.labelTertiary).cgColor
        badgeLabel.textColor = step.state == .failed ? .systemOrange : Theme.Color.labelSecondary
        chevron.image = UIImage(systemName: configuration.expanded ? "chevron.up" : "chevron.down")
        header.accessibilityLabel = "\(SportsCopy.stepOf(step.number, configuration.total)), \(SportsCopy.groupTitle(step.group))"
        header.accessibilityValue = stateLabel.text
        if #available(iOS 18.0, *) {
            header.accessibilityExpandedStatus = configuration.expanded ? .expanded : .collapsed
        }
        guard configuration.body != builtBody else { return }
        builtBody = configuration.body
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        body.isHidden = !configuration.expanded
        guard configuration.expanded else { return }
        body.addArrangedSubview(label(SportsCopy.stepWhat(step.group), font: Theme.Font.subheadline, color: Theme.Color.labelSecondary))
        for check in step.checks {
            body.addArrangedSubview(checkRow(check, configuration))
        }
        if let actions = inlineActions(configuration) {
            body.addArrangedSubview(actions)
        }
    }

    private func checkRow(_ check: SportsCheck, _ configuration: SportsStepConfiguration) -> UIView {
        let requirement = check.requirement ?? .model
        let symbol = UIImageView(image: UIImage(systemName: check.state == .done ? "checkmark.circle.fill" : check.state == .failed ? "exclamationmark.circle.fill" : "circle.dashed"))
        symbol.tintColor = check.state == .done ? Theme.Color.statusOK : check.state == .failed ? .systemOrange : Theme.Color.labelTertiary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        var lines: [UIView] = [label(SportsCopy.title(requirement), font: Theme.Font.subheadlineSemibold, color: Theme.Color.label)]
        let settledHere = check.settledInApp(owner: configuration.owner, settings: configuration.settings)
        if check.state == .done {
            lines.append(label(check.detail.isEmpty ? SportsCopy.why(requirement) : check.detail, font: Theme.Font.footnote, color: Theme.Color.labelSecondary))
        } else {
            lines.append(label(SportsCopy.why(requirement), font: Theme.Font.footnote, color: Theme.Color.labelSecondary))
            if !settledHere, !check.detail.isEmpty {
                lines.append(label(check.detail, font: Theme.Font.footnote, color: check.state == .failed ? .systemOrange : Theme.Color.labelSecondary))
            }
            if !settledHere, let fix = check.fix, let command = sportsCommand(in: fix) {
                lines.append(commandBlock(command, configuration))
            } else if !settledHere, let fix = check.fix {
                lines.append(label(fix, font: Theme.Font.footnote, color: Theme.Color.labelSecondary))
            }
        }
        let text = UIStackView(arrangedSubviews: lines)
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [symbol, text])
        row.alignment = .top
        row.spacing = Theme.Space.xs
        return row
    }

    /// A command for the computer with Plex, set apart in monospaced type, with Copy and Share.
    private func commandBlock(_ command: String, _ configuration: SportsStepConfiguration) -> UIView {
        let text = UILabel()
        text.text = command
        text.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        text.adjustsFontForContentSizeCategory = true
        text.textColor = Theme.Color.label
        text.numberOfLines = 0
        text.lineBreakMode = .byCharWrapping
        let box = UIView()
        box.backgroundColor = Theme.Color.surfaceRaised
        box.layer.cornerRadius = Theme.Radius.xs
        box.layer.cornerCurve = .continuous
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: Theme.Space.xs),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Theme.Space.xs),
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Theme.Space.xs),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Theme.Space.xs),
        ])
        let copy = smallButton(SportsCopy.copyCommand, symbol: "doc.on.doc") { configuration.actions.copy(command) }
        let share = smallButton(SportsCopy.shareCommand, symbol: "square.and.arrow.up") {}
        share.addAction(UIAction { [weak share] _ in if let share { configuration.actions.share(command, share) } }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [copy, share, UIView()])
        buttons.spacing = Theme.Space.xs
        let stack = UIStackView(arrangedSubviews: [label(SportsCopy.onTheServer, font: Theme.Font.caption1Regular, color: Theme.Color.labelSecondary), box, buttons])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xxs
        stack.setCustomSpacing(Theme.Space.xs, after: box)
        return stack
    }

    /// The buttons that settle this step here: agreeing to where searches go, choosing libraries, switching research on.
    private func inlineActions(_ configuration: SportsStepConfiguration) -> UIView? {
        guard configuration.owner else { return nil }
        let step = configuration.step
        let openIDs = Set(step.open.map(\.id))
        var views: [UIView] = []
        if step.group == .web, openIDs.contains(SportsRequirement.agreement.rawValue), let destination = configuration.settings.destination {
            views.append(label(SportsCopy.agreeQuestion(destination), font: Theme.Font.footnote, color: Theme.Color.labelSecondary))
            views.append(prominentButton(SportsCopy.agree, symbol: "hand.thumbsup", enabled: !configuration.busy) { configuration.actions.agree() })
        }
        if step.group == .library {
            if !configuration.libraries.isEmpty {
                let chips = UIStackView(arrangedSubviews: configuration.libraries.map { library in
                    chip(library.chosen ? "\(library.title) · \(SportsCopy.kind(library.kind))" : library.title, chosen: library.chosen, enabled: !configuration.busy) { configuration.actions.library(library) }
                })
                chips.axis = .vertical
                chips.alignment = .fill
                chips.spacing = Theme.Space.xs
                views.append(chips)
            } else {
                views.append(label(SportsCopy.noLibraries, font: Theme.Font.footnote, color: .systemOrange))
            }
            if openIDs.contains(SportsRequirement.on.rawValue) {
                views.append(prominentButton(SportsCopy.researchNewFiles, symbol: "power", enabled: !configuration.busy) { configuration.actions.switchOn() })
            }
        }
        guard !views.isEmpty else { return nil }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Theme.Space.xs
        return stack
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        var configuration = Glass.glassButton { UIButton.Configuration.tinted() }
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.footnoteSemibold
            return attributes
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private func prominentButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = Glass.prominentButton { UIButton.Configuration.filled() }
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = Theme.Color.onAccent
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.isEnabled = enabled
        return button
    }

    private func chip(_ title: String, chosen: Bool, enabled: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = chosen ? UIButton.Configuration.tinted() : UIButton.Configuration.gray()
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.title = title
        configuration.image = UIImage(systemName: chosen ? "checkmark.circle.fill" : "circle")
        configuration.imagePadding = 10
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        configuration.contentInsets.leading = Theme.Space.m
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        button.isEnabled = enabled
        button.accessibilityTraits.insert(chosen ? .selected : [])
        return button
    }
}
