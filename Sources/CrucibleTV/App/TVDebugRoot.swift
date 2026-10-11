#if DEBUG
import UIKit

/// The DEBUG-only hook that lets a development build replace the whole app with a standalone
/// screen (the design gallery). The coordinator asks before it touches the session.
enum TVDebugRoot {
    static func rootIfRequested() -> UIViewController? {
        nil
    }
}
#endif
