import UIKit

/// Navigation rules shared by every tvOS screen: one guarded push, a Reduce-Motion-aware pop and the
/// navigation controller with its bar hidden that every tab and the launch root use.
@MainActor
enum TVNavigation {
    /// Pushes `controller` on the navigation stack that holds `presenter`. A second push while the
    /// first is still in flight, or from a screen that is no longer on top, is ignored: two quick
    /// clicks of the Siri Remote must not stack two identical detail screens. Returns whether the
    /// push happened.
    @discardableResult
    static func push(_ controller: UIViewController, from presenter: UIViewController) -> Bool {
        guard let navigation = presenter.navigationController,
              isOnTop(presenter, in: navigation),
              navigation.transitionCoordinator == nil,
              presenter.presentedViewController == nil
        else { return false }
        navigation.pushViewController(controller, animated: TVMotion.animationsEnabled)
        return true
    }

    @discardableResult
    static func pop(from presenter: UIViewController) -> Bool {
        guard let navigation = presenter.navigationController,
              isOnTop(presenter, in: navigation),
              navigation.transitionCoordinator == nil
        else { return false }
        navigation.popViewController(animated: TVMotion.animationsEnabled)
        return true
    }

    static func makeNavigationController(root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.setNavigationBarHidden(true, animated: false)
        return navigation
    }

    private static func isOnTop(_ presenter: UIViewController, in navigation: UINavigationController) -> Bool {
        var candidate: UIViewController? = presenter
        while let controller = candidate {
            if controller === navigation.topViewController { return true }
            candidate = controller.parent
        }
        return false
    }
}
