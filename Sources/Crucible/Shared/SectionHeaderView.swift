import UIKit

struct SectionHeaderConfiguration: UIContentConfiguration, Hashable {
    var title: String = ""

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

    init(configuration: SectionHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? SectionHeaderConfiguration else { return }
        titleLabel.text = config.title
    }
}
