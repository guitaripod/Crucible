import CrucibleDesign
import UIKit

/// The loading, empty and error screens, built on `UIContentUnavailableConfiguration` so they match
/// the system's own states. Add it as a full-screen subview or as a child's view and call `show`.
///
/// A state with a button hands focus to that button. A state without one (loading, or an empty
/// state with no action) hands focus to a `TVFocusAnchorView`, so the remote never falls through
/// to the tab bar and Menu still pops a pushed screen instead of leaving the app.
final class TVStateView: UIView {
    enum State {
        case loading(title: String?)
        case empty(title: String, message: String?, symbol: String, action: Action?)
        case error(title: String, message: String?, retryTitle: String, retry: @MainActor () -> Void, secondary: Action? = nil)
    }

    struct Action {
        var title: String
        var handler: @MainActor () -> Void
    }

    private let stateView = UIContentUnavailableView(configuration: .loading())
    private let anchor = TVFocusAnchorView()
    private var hasButton = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        anchor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateView)
        addSubview(anchor)
        NSLayoutConstraint.activate([
            anchor.centerXAnchor.constraint(equalTo: centerXAnchor),
            anchor.centerYAnchor.constraint(equalTo: centerYAnchor),
            anchor.widthAnchor.constraint(equalToConstant: 2),
            anchor.heightAnchor.constraint(equalToConstant: 2),
            stateView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualToConstant: TVMetrics.Column.wide),
            stateView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stateView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { hasButton ? [stateView] : [anchor] }

    func show(_ state: State) {
        stateView.configuration = Self.configuration(for: state)
        hasButton = Self.hasButton(state)
        accessibilityElements = [stateView]
    }

    private static func hasButton(_ state: State) -> Bool {
        switch state {
        case .loading: false
        case .empty(_, _, _, let action): action != nil
        case .error: true
        }
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
        case .error(let title, let message, let retryTitle, let retry, let secondary):
            configuration = .empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = title
            configuration.secondaryText = message
            attach(retryTitle, handler: retry, to: &configuration)
            if let secondary { attachSecondary(secondary, to: &configuration) }
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

    private static func attachSecondary(_ action: Action, to configuration: inout UIContentUnavailableConfiguration) {
        configuration.secondaryButton = TVButton.configuration(.glass, title: action.title)
        configuration.secondaryButtonProperties.primaryAction = UIAction { _ in action.handler() }
    }

    private static func style(_ configuration: inout UIContentUnavailableConfiguration) {
        configuration.textProperties.font = Theme.Font.title3
        configuration.textProperties.color = Theme.Color.label
        configuration.secondaryTextProperties.font = Theme.Font.body
        configuration.secondaryTextProperties.color = Theme.Color.labelSecondary
        configuration.imageProperties.tintColor = Theme.Color.labelTertiary
        configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.state, weight: .light)
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
