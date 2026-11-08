import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The top of the Request sheet: the poster, the title and year, where it stands in Seerr and what it is about.
struct SeerrTitleHeaderConfiguration: UIContentConfiguration {
    var title: String
    var year: Int?
    var availability: SeerrAvailability?
    var overview: String?
    var poster: UIImage?

    func makeContentView() -> UIView & UIContentView {
        SeerrTitleHeaderView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SeerrTitleHeaderConfiguration { self }
}

final class SeerrTitleHeaderView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let posterView = UIImageView()
    private let titleLabel = UILabel()
    private let yearLabel = UILabel()
    private let stateIcon = UIImageView()
    private let stateLabel = UILabel()
    private let detailLabel = UILabel()
    private let overviewLabel = UILabel()

    init(configuration: SeerrTitleHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.layer.cornerRadius = Theme.Radius.s
        posterView.layer.cornerCurve = .continuous
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 3
        titleLabel.adjustsFontForContentSizeCategory = true
        yearLabel.font = Theme.Font.subheadline
        yearLabel.textColor = Theme.Color.labelSecondary
        stateIcon.tintColor = Theme.Color.accent
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        stateLabel.font = Theme.Font.subheadlineSemibold
        stateLabel.textColor = Theme.Color.accentText
        stateLabel.numberOfLines = 2
        detailLabel.font = Theme.Font.footnote
        detailLabel.textColor = Theme.Color.labelSecondary
        overviewLabel.font = Theme.Font.footnote
        overviewLabel.textColor = Theme.Color.labelSecondary
        overviewLabel.numberOfLines = 6

        let stateRow = UIStackView(arrangedSubviews: [stateIcon, stateLabel])
        stateRow.spacing = Theme.Space.xs
        stateRow.alignment = .center
        let text = UIStackView(arrangedSubviews: [titleLabel, yearLabel, stateRow, detailLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.m, after: yearLabel)
        let top = UIStackView(arrangedSubviews: [posterView, text])
        top.spacing = Theme.Space.m
        top.alignment = .top
        let stack = UIStackView(arrangedSubviews: [top, overviewLabel])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            posterView.widthAnchor.constraint(equalToConstant: 96),
            posterView.heightAnchor.constraint(equalTo: posterView.widthAnchor, multiplier: 1.5),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.m, leading: Theme.Space.m, bottom: Theme.Space.m, trailing: Theme.Space.m)
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SeerrTitleHeaderConfiguration else { return }
        posterView.image = configuration.poster
        titleLabel.text = configuration.title
        yearLabel.text = configuration.year.map(String.init)
        yearLabel.isHidden = configuration.year == nil
        let state = configuration.availability
        stateIcon.image = state.map { UIImage(systemName: SeerrCopy.symbol($0)) } ?? nil
        stateLabel.text = state.map(SeerrCopy.label)
        stateIcon.superview?.isHidden = state == nil
        detailLabel.text = state.flatMap { SeerrCopy.detail($0) }
        detailLabel.isHidden = detailLabel.text == nil
        overviewLabel.text = configuration.overview
        overviewLabel.isHidden = configuration.overview?.isEmpty ?? true
        accessibilityIdentifier = "seerr.header"
        accessibilityLabel = [configuration.title, configuration.year.map(String.init), stateLabel.text, detailLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = state.map(SeerrCopy.label)
    }
}
