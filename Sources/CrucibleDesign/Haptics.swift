import UIKit

/// One entry point for tactile feedback so every screen speaks the same vocabulary. Apple TV has
/// no haptic hardware, so every call is a no-op there.
@MainActor
package enum Haptics {
    #if os(iOS)
    package static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    package static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    package static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    package static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    package static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    package static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    #else
    package static func selection() {}

    package static func light() {}

    package static func medium() {}

    package static func soft() {}

    package static func success() {}

    package static func error() {}
    #endif
}
