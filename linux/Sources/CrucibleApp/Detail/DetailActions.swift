import CrucibleUI
import Foundation
import Kiln

/// One button of a title page's action row (`TVDetailAction`): it runs something, or opens a menu of choices.
struct DetailAction {
    enum Behaviour {
        case run(() -> Void)
        case menu(title: String?, items: [MenuView.Item], choose: (MenuView.Item) -> Void)
    }

    /// Stable across rebuilds, so the focus stays on the same button when the page refreshes.
    var id: String
    var title: String
    var symbol: Symbol?
    var isPrimary = false
    var isEnabled = true
    var behaviour: Behaviour
}

/// A title page's actions: Play first in the accent, the rest glass, scrolling sideways past the window's edge. A rebuild
/// keeps each button (and the focus on it) by its id, so a refresh after playback never moves the focus.
@MainActor
final class DetailActionRow: View {
    private let scroller = ScrollView(axis: .horizontal)
    private var actions: [DetailAction] = []
    private var buttons: [String: ButtonView] = [:]

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        scroller.showsIndicator = false
        addSubview(scroller)
    }

    override var remembersFocus: Bool { true }
    override var preferredFocusView: View? { actions.first.flatMap { buttons[$0.id] } }

    func setActions(_ newActions: [DetailAction]) {
        actions = newActions
        var next: [String: ButtonView] = [:]
        for action in newActions {
            let style: ButtonView.Style = action.isPrimary ? .primary : .glass
            let button = buttons[action.id] ?? ButtonView(style: style, title: action.title, symbol: action.symbol)
            button.style = style
            button.title = action.title
            button.symbol = action.symbol
            button.isEnabled = action.isEnabled
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.perform(action, from: button)
            }
            if button.superview == nil { scroller.addSubview(button) }
            next[action.id] = button
        }
        for (id, button) in buttons where next[id] == nil { button.removeFromSuperview() }
        buttons = next
        setNeedsLayout()
    }

    private func perform(_ action: DetailAction, from button: ButtonView) {
        switch action.behaviour {
        case .run(let run):
            run()
        case .menu(let title, let items, let choose):
            guard let window else { return }
            let menu = MenuView(title: title, items: items, anchor: button.frameInWindow)
            menu.onSelect = choose
            menu.present(in: window)
        }
    }

    override func sizeThatFits(_ size: Size) -> Size {
        Size(width: size.width, height: Theme.current.metrics.primaryControlHeight + Theme.current.metrics.tv(48))
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        scroller.frame = bounds
        scroller.revealInsets = EdgeInsets(leading: metrics.sideMargin, trailing: metrics.sideMargin)
        var x = metrics.sideMargin
        let y = (frame.height - metrics.primaryControlHeight) / 2
        for action in actions {
            guard let button = buttons[action.id] else { continue }
            let size = button.sizeThatFits(Size(width: 1200, height: metrics.primaryControlHeight))
            button.frame = Rect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + metrics.tv(28)
        }
        scroller.contentLength = x - metrics.tv(28) + metrics.sideMargin
    }
}
