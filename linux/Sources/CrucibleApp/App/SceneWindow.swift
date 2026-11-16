import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// A window beside the first one (Ctrl+N, a title opened in a new window), as the iPad opens scenes beside its launch
/// leader (`SceneDelegate.launchLeader`): its own tabs, screens and player over the first window's connection, which the
/// app coordinator keeps. Signing out or changing server closes it; closing the first window hands that role to it.
@MainActor
final class SceneWindow: WindowDelegate {
    let window: Window
    let root: RootView
    let router = Router()
    /// The window's close button or Ctrl+W.
    var onClose: ((SceneWindow) -> Void)?
    /// Ctrl+Q and Quit Crucible.
    var onQuit: (() -> Void)?
    /// The window gained or lost the keyboard.
    var onFocusChange: ((SceneWindow, Bool) -> Void)?
    /// A title asked to open in yet another window.
    var onOpenInNewWindow: ((URL) -> Void)?

    init(window: Window, root: RootView) {
        self.window = window
        self.root = root
        window.delegate = self
        window.contentView = root
        window.background = Theme.current.palette.canvas
        window.focus.focus(root, animated: false)
        router.activate(root)
    }

    /// Stops what plays and closes the window.
    func close() {
        router.deactivate()
        root.closePlayer()
        window.close()
    }

    /// Lets the window go without closing it, when the coordinator takes it over as its first window.
    func handOver() {
        router.deactivate()
        onClose = nil
        onQuit = nil
        onFocusChange = nil
        onOpenInNewWindow = nil
    }

    func window(_ window: Window, unhandledKey event: KeyEvent) -> Bool {
        if event.key == Key.character("q") && event.modifiers == .control {
            onQuit?()
            return true
        }
        return root.handleWindowKey(event, in: window)
    }

    func window(_ window: Window, unhandledButton button: MouseButton) -> Bool {
        switch button {
        case .back: return root.handleBack()
        case .forward: return root.handleForward()
        default: return false
        }
    }

    func window(_ window: Window, zoomScrolled event: ScrollEvent) -> Bool {
        root.zoomScrolled(event)
    }

    func window(_ window: Window, keyboardFocusChanged focused: Bool) {
        if focused { DesktopAccessibility.apply(to: window) }
        onFocusChange?(self, focused)
    }

    func window(_ window: Window, openInNewWindow link: URL) {
        onOpenInNewWindow?(link)
    }

    func windowShouldClose(_ window: Window) {
        onClose?(self)
    }
}
