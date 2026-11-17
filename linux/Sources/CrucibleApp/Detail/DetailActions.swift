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

/// A title page's actions: Play first in the accent, the rest glass, wrapping onto further lines where the window ends so
/// every one is in reach of a mouse. A rebuild keeps each button (and the focus on it) by its id, so a refresh after
/// playback never moves the focus.
@MainActor
final class DetailActionRow: View {
    private var actions: [DetailAction] = []
    private var buttons: [String: ButtonView] = [:]

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
            if case .menu = action.behaviour {
                button.symbol = "chevron.down"
                button.symbolTrailing = true
            } else {
                button.symbol = action.symbol
                button.symbolTrailing = false
            }
            button.isEnabled = action.isEnabled
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.perform(action, from: button)
            }
            if button.superview == nil { addSubview(button) }
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

    private func flow(width: Float) -> FlowLayout {
        let metrics = Theme.current.metrics
        return FlowLayout(leading: metrics.sideMargin, width: width - metrics.sideMargin * 2, spacing: metrics.tv(28), lineSpacing: metrics.tv(24))
    }

    private var padding: Float { Theme.current.metrics.tv(48) }

    private var buttonsInOrder: [ButtonView] { actions.compactMap { buttons[$0.id] } }

    /// Each button's size, which is its own: a button is as wide as its title.
    private func buttonSizes() -> [Size] {
        let limit = Size(width: 1200, height: Theme.current.metrics.primaryControlHeight)
        return buttonsInOrder.map { $0.sizeThatFits(limit) }
    }

    override func sizeThatFits(_ size: Size) -> Size {
        let placed = flow(width: size.width).place(buttonSizes())
        return Size(width: size.width, height: placed.height + padding)
    }

    override func layoutSubviews() {
        let sizes = buttonSizes()
        let placed = flow(width: frame.width).place(sizes)
        for (index, button) in buttonsInOrder.enumerated() {
            button.frame = Rect(x: placed.origins[index].x, y: padding / 2 + placed.origins[index].y, width: sizes[index].width, height: sizes[index].height)
        }
    }
}
