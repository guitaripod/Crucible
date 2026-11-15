import Foundation
import Kiln

/// What every CrucibleUI view with selectable text shares (titles, synopses, facts): the selection's colour, a drag or
/// a double or triple click to select, and a right click that selects the block under it when nothing in it is and
/// offers Copy.
@MainActor
enum SelectableText {
    static var highlight: Color { Theme.current.palette.accent.withSRGBAlpha(0.3) }

    /// A press on `view`'s text; returns false when it missed the text, so the press goes on to what is behind.
    static func press(_ button: MouseButton, at point: Point, selector: TextSelector, in view: View & TextSelecting) -> Bool {
        guard let window = view.window else { return false }
        switch button {
        case .primary:
            guard selector.press(at: point, clicks: window.clickCount) else { return false }
            window.claimSelection(view)
            return true
        case .secondary:
            guard let key = selector.block(at: point) else { return false }
            if selector.selection?.block != key || selector.selectedText == nil { selector.selectAll(in: key) }
            window.claimSelection(view)
            presentCopy(at: view.transformToWindow.apply(point), selector: selector, in: window)
            return true
        default:
            return false
        }
    }

    /// The text cursor over the text, the view's own elsewhere.
    static func cursor(at point: Point, selector: TextSelector, otherwise: Cursor) -> Cursor {
        selector.block(at: point) == nil ? otherwise : .text
    }

    private static func presentCopy(at point: Point, selector: TextSelector, in window: Window) {
        let copy = MenuView.Item(id: "copy", title: Strings.lookup("Copy"), symbol: "doc.on.doc", shortcut: Strings.lookup("Ctrl") + "+C")
        let menu = MenuView(items: [copy], anchor: Rect(x: point.x, y: point.y, width: 1, height: 1))
        menu.onSelect = { [weak selector, weak window] _ in
            guard let text = selector?.selectedText else { return }
            window?.copy(text)
        }
        menu.present(in: window)
    }
}
