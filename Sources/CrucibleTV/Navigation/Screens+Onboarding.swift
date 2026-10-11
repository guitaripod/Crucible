import CrucibleCore
import CrucibleDesign
import UIKit

extension TVScreens {
    static func onboarding(
        mode: TVOnboardingMode,
        onConnected: @escaping @MainActor (PlexConnection) -> Void
    ) -> UIViewController {
        TVSignInPlaceholderViewController()
    }
}

private final class TVSignInPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas

        var configuration = Glass.glassButton { UIButton.Configuration.filled() }
        configuration.title = "Sign in"
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "onboarding.signIn"
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
