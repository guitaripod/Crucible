import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// A screen in a navigation stack: a full-size view that knows when it shows and hides, and whether the tab bar floats
/// over it.
@MainActor
class ScreenView: View {
    weak var navigation: NavigationView?

    /// Whether the tab bar stays over this screen (root screens) or slides away (pushed ones keep it reachable by
    /// moving up).
    var showsTabBar: Bool { true }

    func screenDidAppear() {}
    func screenWillDisappear() {}

    /// Escape on this screen: return true to keep it (a search field clearing its text first).
    func handleBack() -> Bool { false }
}

/// A stack of screens with the tvOS push: the new screen fades in as it settles from a little to the right, the old one
/// fades out; popping runs it backwards. Focus moves to the new screen's preferred view, and returns to where it was on
/// the screen below when popped.
@MainActor
final class NavigationView: View {
    private(set) var screens: [ScreenView] = []
    private var transition = Animated(1)
    private var outgoing: ScreenView?
    private var direction: Float = 1
    private var focusMemory: [ObjectIdentifier: View] = [:]

    var top: ScreenView? { screens.last }
    var onChange: (() -> Void)?

    init(root: ScreenView) {
        super.init()
        push(root, animated: false)
    }

    func push(_ screen: ScreenView, animated: Bool = true) {
        if let current = screens.last {
            if let focused = window?.focusedView, focused.isDescendant(of: current) { focusMemory[ObjectIdentifier(current)] = focused }
            current.screenWillDisappear()
        }
        screen.navigation = self
        screens.append(screen)
        addSubview(screen)
        screen.frame = bounds
        begin(from: screens.count > 1 ? screens[screens.count - 2] : nil, forward: true, animated: animated)
        window?.focus.focus(screen, animated: false)
        screen.screenDidAppear()
        onChange?()
    }

    @discardableResult
    func pop(animated: Bool = true) -> Bool {
        guard screens.count > 1, let leaving = screens.popLast() else { return false }
        leaving.screenWillDisappear()
        let revealed = screens[screens.count - 1]
        revealed.isHidden = false
        begin(from: leaving, forward: false, animated: animated)
        if let remembered = focusMemory.removeValue(forKey: ObjectIdentifier(revealed)), remembered.isDescendant(of: revealed) {
            window?.focus.focus(remembered, animated: false)
        } else {
            window?.focus.focus(revealed, animated: false)
        }
        revealed.screenDidAppear()
        onChange?()
        return true
    }

    func popToRoot() {
        while screens.count > 1 { pop(animated: screens.count == 2) }
    }

    private func begin(from previous: ScreenView?, forward: Bool, animated: Bool) {
        if let outgoing, outgoing !== previous, !screens.contains(where: { $0 === outgoing }) { outgoing.removeFromSuperview() }
        outgoing = previous
        direction = forward ? 1 : -1
        if animated && previous != nil {
            transition.reset(0)
            transition.set(1, animation: .timed(duration: 0.32, curve: .easeOut))
            startAnimating()
        } else {
            transition.reset(1)
            finish()
        }
        apply()
    }

    private func finish() {
        guard let outgoing else { return }
        if screens.contains(where: { $0 === outgoing }) {
            outgoing.isHidden = true
        } else {
            outgoing.removeFromSuperview()
        }
        outgoing.alpha = 1
        outgoing.translation = .zero
        self.outgoing = nil
    }

    private func apply() {
        let shift = Theme.current.metrics.tv(80)
        let t = transition.value
        if let top = screens.last {
            top.alpha = direction > 0 ? t : 1
            top.translation = direction > 0 ? Point(x: (1 - t) * shift, y: 0) : .zero
        }
        if let outgoing {
            outgoing.alpha = direction > 0 ? 1 - t : 1 - t
            outgoing.translation = direction > 0 ? Point(x: -t * shift * 0.3, y: 0) : Point(x: t * shift, y: 0)
            if direction < 0, let top = screens.last {
                top.alpha = t
                top.translation = Point(x: -(1 - t) * shift * 0.3, y: 0)
            }
        }
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = transition.advance(dt)
        apply()
        if !moving { finish() }
        setNeedsDisplay()
        return moving
    }

    override var preferredFocusView: View? { screens.last }

    override func layoutSubviews() {
        for screen in screens { screen.frame = bounds }
        outgoing?.frame = bounds
    }
}
