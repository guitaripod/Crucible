#if canImport(UIKit)
import UIKit

/// Tells the first look at Home after the app was opened, or brought back from the background, apart from every later
/// return to Home from another screen: only the first is a viewer who came to carry on, and the title Home leads with is
/// made ready for them from the start, since a stream takes a second or two to load and they press within about that.
@MainActor
package enum AppOpening {
    private static var isFresh = true
    private static var observer: (any NSObjectProtocol)?

    /// Whether this is the first ask since the app came to the foreground; asking uses it up.
    package static func take() -> Bool {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isFresh = true }
            }
        }
        defer { isFresh = false }
        return isFresh
    }
}
#endif
