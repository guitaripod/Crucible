import MidgarCore
import UIKit

/// Holding the Library tab opens the menu the library's title opens. UIKit gives a tab no menu of its own, so the menu's
/// interaction rides on the tab's own view in the tab bar, found by the label VoiceOver reads for it, and moves to the
/// new view whenever the tab bar lays its tabs out anew. Nothing private is used: where the view cannot be found, the
/// tab simply has no menu.
@MainActor
final class LibraryTabMenu: NSObject, UIContextMenuInteractionDelegate {
    private let title: String
    private let menu: () -> UIMenu?
    private let hosts = NSHashTable<UIView>.weakObjects()

    /// `title` is the Library tab's title as the tab bar shows it; `menu` gives the menu when the tab is held, or nil for none.
    init(title: String, menu: @escaping () -> UIMenu?) {
        self.title = title
        self.menu = menu
    }

    /// Puts the menu on every view of the Library tab in `tabBar` that does not have it yet: the bar draws each tab twice,
    /// once as it rests and once inside the glass that marks the selected tab. The tab bar's own gestures (the selection
    /// that follows a finger along the bar) would take a held finger first, so on that tab they wait for the menu's
    /// gestures to fail: a tap still selects the tab, a hold opens the menu, and the bar slides elsewhere as ever.
    func attach(in tabBar: UITabBar) {
        for view in Self.views(labelled: title, in: tabBar) where !hosts.contains(view) {
            let before = Set((view.gestureRecognizers ?? []).map(ObjectIdentifier.init))
            view.addInteraction(UIContextMenuInteraction(delegate: self))
            let menuGestures = (view.gestureRecognizers ?? []).filter { !before.contains(ObjectIdentifier($0)) }
            var ancestor = view.superview
            while let current = ancestor {
                for gesture in current.gestureRecognizers ?? [] {
                    menuGestures.forEach(gesture.require(toFail:))
                }
                ancestor = current === tabBar ? nil : current.superview
            }
            hosts.add(view)
            MidgarLog.info("Library tab menu: on a view of the Library tab in \(view.superview.map { String(describing: type(of: $0)) } ?? "nothing")", category: .ui)
        }
    }

    /// Every view under `root` that VoiceOver reads as `label`.
    private static func views(labelled label: String, in root: UIView) -> [UIView] {
        root.subviews.flatMap { view -> [UIView] in
            if view.isAccessibilityElement, view.accessibilityLabel == label {
                return [view]
            }
            return Self.views(labelled: label, in: view)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menu() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
