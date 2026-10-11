import UIKit

final class PlaceholderViewController: UIViewController {
    static let canvas = UIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)

    private let titleLabel = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.canvas

        titleLabel.text = "Crucible for Apple TV"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "placeholder.title"

        button.configuration = Self.buttonConfiguration(title: "Press Select")
        button.accessibilityIdentifier = "placeholder.button"
        button.addAction(UIAction { [weak self] _ in
            self?.button.configuration = Self.buttonConfiguration(title: "Selected")
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 60
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    private static func buttonConfiguration(title: String) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        if #available(tvOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
        }
        configuration.title = title
        return configuration
    }
}
