import CAccessKit
import Foundation

/// The window's link to screen readers: AccessKit's Unix adapter, which speaks AT-SPI and wakes only when an assistive
/// tool such as Orca is listening. While one is, the window's tree goes to it whenever the focus moves and, at most four
/// times a second, after frames that changed what is on screen; its requests (focus this, press that) come back here.
@MainActor
final class AccessibilityBridge {
    /// The adapter's callbacks arrive on its own thread with this box, which finds the bridge on the main actor.
    private final class Callbacks: @unchecked Sendable {
        weak var bridge: AccessibilityBridge?
    }

    private weak var window: Window?
    private let title: String
    private var adapter: OpaquePointer?
    private let callbacks = Callbacks()
    private var pushPending = false
    private var lastPush: Double = 0
    /// Whether a screen reader is listening.
    private(set) var isActive = false
    /// Called when a screen reader starts or stops listening.
    var onActiveChange: ((Bool) -> Void)?

    private static let pushInterval = 0.25

    init(window: Window, title: String) {
        self.window = window
        self.title = title
        callbacks.bridge = self
        let context = Unmanaged.passUnretained(callbacks).toOpaque()
        adapter = accesskit_unix_adapter_new(AccessibilityBridge.activated, context, AccessibilityBridge.requested, context,
                                             AccessibilityBridge.deactivated, context)
    }

    isolated deinit {
        if let adapter { accesskit_unix_adapter_free(adapter) }
    }

    /// The focus moved: the screen reader hears it on the next turn of the loop.
    func focusChanged() {
        schedulePush(after: 0)
    }

    /// A frame was drawn: what it shows reaches the screen reader within a quarter second.
    func frameDrawn() {
        schedulePush(after: max(0, AccessibilityBridge.pushInterval - (Window.now() - lastPush)))
    }

    func windowFocusChanged(_ focused: Bool) {
        if let adapter { accesskit_unix_adapter_update_window_focus_state(adapter, focused) }
    }

    private func schedulePush(after delay: Double) {
        guard isActive, !pushPending else { return }
        pushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pushPending = false
                self.push()
            }
        }
    }

    /// Hands the adapter the whole tree; it works out what changed and tells the screen reader.
    private func push() {
        guard isActive, let adapter else { return }
        lastPush = Window.now()
        let context = Unmanaged.passUnretained(callbacks).toOpaque()
        accesskit_unix_adapter_update_if_active(adapter, AccessibilityBridge.makeUpdate, context)
    }

    /// The window's tree in AccessKit's terms, in physical pixels as it measures bounds.
    fileprivate func treeUpdate() -> OpaquePointer {
        guard let window else {
            let update = accesskit_tree_update_with_focus(AccessibilityTree.rootID)!
            let root = accesskit_node_new(UInt8(ACCESSKIT_ROLE_WINDOW.rawValue))
            accesskit_tree_update_push_node(update, AccessibilityTree.rootID, root)
            accesskit_tree_update_set_tree_info(update, accesskit_tree_info_new(AccessibilityTree.rootID))
            return update
        }
        let snapshot = AccessibilityTree.snapshot(of: window, title: title)
        let update = accesskit_tree_update_with_capacity_and_focus(snapshot.nodes.count, snapshot.focus)!
        let scale = Double(window.scale)
        for node in snapshot.nodes {
            accesskit_tree_update_push_node(update, node.id, AccessibilityBridge.makeNode(node, scale: scale))
        }
        let info = accesskit_tree_info_new(AccessibilityTree.rootID)
        accesskit_tree_info_set_toolkit_name(info, "Kiln")
        accesskit_tree_update_set_tree_info(update, info)
        return update
    }

    /// One node in AccessKit's terms. A label's text goes in its value, where AccessKit reads a label's name from, with its
    /// state after it.
    private static func makeNode(_ node: AccessibilityNode, scale: Double) -> OpaquePointer {
        let made = accesskit_node_new(node.role.accessKit)!
        if node.role == .label {
            let text = [node.label, node.value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            if !text.isEmpty { accesskit_node_set_value(made, text) }
        } else {
            if let label = node.label, !label.isEmpty { accesskit_node_set_label(made, label) }
            if let value = node.value, !value.isEmpty { accesskit_node_set_value(made, value) }
        }
        if let hint = node.hint, !hint.isEmpty { accesskit_node_set_description(made, hint) }
        if let selected = node.isSelected { accesskit_node_set_selected(made, selected) }
        let bounds = node.bounds
        accesskit_node_set_bounds(made, accesskit_rect(x0: Double(bounds.minX) * scale, y0: Double(bounds.minY) * scale,
                                                       x1: Double(bounds.maxX) * scale, y1: Double(bounds.maxY) * scale))
        for child in node.children { accesskit_node_push_child(made, child) }
        if node.isFocusable {
            accesskit_node_add_action(made, UInt8(ACCESSKIT_ACTION_FOCUS.rawValue))
            accesskit_node_add_action(made, UInt8(ACCESSKIT_ACTION_CLICK.rawValue))
            accesskit_node_add_action(made, UInt8(ACCESSKIT_ACTION_SHOW_CONTEXT_MENU.rawValue))
        }
        if node.id != AccessibilityTree.rootID { accesskit_node_add_action(made, UInt8(ACCESSKIT_ACTION_SCROLL_INTO_VIEW.rawValue)) }
        return made
    }

    private func activate() {
        guard !isActive else { return }
        isActive = true
        onActiveChange?(true)
        push()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        onActiveChange?(false)
    }

    /// Carries out a screen reader's request on the view it names.
    private func perform(_ action: UInt8, on id: UInt64) {
        guard let window, let view = AccessibilityBridge.view(id, in: window.contentView) else { return }
        switch UInt32(action) {
        case ACCESSKIT_ACTION_FOCUS.rawValue:
            window.focus.focus(view)
        case ACCESSKIT_ACTION_CLICK.rawValue:
            if view.canBecomeFocused { window.focus.focus(view, animated: true, reveal: true) }
            view.activate()
        case ACCESSKIT_ACTION_SHOW_CONTEXT_MENU.rawValue:
            _ = view.showContextMenu(at: nil)
        case ACCESSKIT_ACTION_SCROLL_INTO_VIEW.rawValue:
            view.superview?.reveal(view.frame, of: view, animated: true)
        default:
            break
        }
    }

    private static func view(_ id: UInt64, in root: View) -> View? {
        if root.accessibilityID == id { return root }
        for subview in root.subviews {
            if let found = view(id, in: subview) { return found }
        }
        return nil
    }

    /// Runs `body` with the bridge on the main actor, from a callback on the adapter's thread.
    private nonisolated static func onMain(_ context: UnsafeMutableRawPointer?, _ body: @escaping @MainActor (AccessibilityBridge) -> Void) {
        guard let context else { return }
        let callbacks = Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let bridge = callbacks.bridge else { return }
                body(bridge)
            }
        }
    }

    /// A screen reader appeared: no tree yet from this thread; the main actor pushes the first one.
    private static let activated: accesskit_activation_handler_callback = { context in
        AccessibilityBridge.onMain(context) { $0.activate() }
        return nil
    }

    private static let deactivated: accesskit_deactivation_handler_callback = { context in
        AccessibilityBridge.onMain(context) { $0.deactivate() }
    }

    private static let requested: accesskit_action_handler_callback = { request, context in
        guard let request else { return }
        let action = request.pointee.action
        let target = request.pointee.target_node
        accesskit_action_request_free(request)
        AccessibilityBridge.onMain(context) { $0.perform(action, on: target) }
    }

    /// Called by `update_if_active` on the main thread, so the tree can be read where it lives. The update crosses out of
    /// the main actor's closure as an address, since the pointer type is not sendable.
    private static let makeUpdate: accesskit_tree_update_factory = { context in
        let callbacks = Unmanaged<Callbacks>.fromOpaque(context!).takeUnretainedValue()
        let address = MainActor.assumeIsolated { () -> Int in
            let update: OpaquePointer
            if let bridge = callbacks.bridge {
                update = bridge.treeUpdate()
            } else {
                update = accesskit_tree_update_with_focus(AccessibilityTree.rootID)!
                accesskit_tree_update_push_node(update, AccessibilityTree.rootID, accesskit_node_new(UInt8(ACCESSKIT_ROLE_WINDOW.rawValue)))
                accesskit_tree_update_set_tree_info(update, accesskit_tree_info_new(AccessibilityTree.rootID))
            }
            return Int(bitPattern: update)
        }
        return OpaquePointer(bitPattern: address)
    }
}
