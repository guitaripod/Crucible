import CrucibleDesign
import UIKit

/// The loading, empty and error screens, built on `UIContentUnavailableConfiguration` so they match
/// the system's own states. Add it as a full-screen subview or as a child's view and call `show`.
final class TVStateView: UIView {
    enum State {
        case loading(title: String?)
        case empty(title: String, message: String?, symbol: String, action: Action?)
        case error(title: String, message: String?, retryTitle: String, retry: @MainActor () -> Void)
    }

    struct Action {
        var title: String
        var handler: @MainActor () -> Void
    }

    private let stateView = UIContentUnavailableView(configuration: .loading())

    override init(frame: CGRect) {
        super.init(frame: frame)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            stateView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stateView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [stateView] }

    func show(_ state: State) {
        stateView.configuration = Self.configuration(for: state)
        accessibilityElements = [stateView]
    }

    private static func configuration(for state: State) -> UIContentUnavailableConfiguration {
        var configuration: UIContentUnavailableConfiguration
        switch state {
        case .loading(let title):
            configuration = .loading()
            configuration.text = title
        case .empty(let title, let message, let symbol, let action):
            configuration = .empty()
            configuration.image = UIImage(systemName: symbol)
            configuration.text = title
            configuration.secondaryText = message
            if let action { attach(action.title, handler: action.handler, to: &configuration) }
        case .error(let title, let message, let retryTitle, let retry):
            configuration = .empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = title
            configuration.secondaryText = message
            attach(retryTitle, handler: retry, to: &configuration)
        }
        style(&configuration)
        return configuration
    }

    private static func attach(
        _ title: String,
        handler: @escaping @MainActor () -> Void,
        to configuration: inout UIContentUnavailableConfiguration
    ) {
        configuration.button = TVButton.configuration(.primary, title: title)
        configuration.buttonProperties.primaryAction = UIAction { _ in handler() }
    }

    private static func style(_ configuration: inout UIContentUnavailableConfiguration) {
        configuration.textProperties.font = Theme.Font.title3
        configuration.textProperties.color = Theme.Color.label
        configuration.secondaryTextProperties.font = Theme.Font.body
        configuration.secondaryTextProperties.color = Theme.Color.labelSecondary
        configuration.imageProperties.tintColor = Theme.Color.labelTertiary
        configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 80, weight: .light)
        configuration.textToSecondaryTextPadding = Theme.Space.xs
        configuration.imageToTextPadding = Theme.Space.s
        configuration.buttonToSecondaryButtonPadding = Theme.Space.s
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Space.m,
            leading: Theme.Space.l,
            bottom: Theme.Space.m,
            trailing: Theme.Space.l
        )
    }
}
