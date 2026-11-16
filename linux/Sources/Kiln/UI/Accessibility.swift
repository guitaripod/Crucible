import CAccessKit
import Foundation

/// The roles Kiln's views take for a screen reader, after AccessKit's (and through it AT-SPI's).
public enum AccessibilityRole: Sendable {
    case none, window, button, link, label, paragraph, heading, image, group, list, listItem, tabList, tab, menu, menuItem, textInput,
         searchInput, passwordInput, multilineTextInput, dialog, alertDialog, progressIndicator, slider, toolbar, status

    /// AccessKit's role byte for it.
    var accessKit: UInt8 {
        let role = switch self {
        case .none: ACCESSKIT_ROLE_GENERIC_CONTAINER
        case .window: ACCESSKIT_ROLE_WINDOW
        case .button: ACCESSKIT_ROLE_BUTTON
        case .link: ACCESSKIT_ROLE_LINK
        case .label: ACCESSKIT_ROLE_LABEL
        case .paragraph: ACCESSKIT_ROLE_PARAGRAPH
        case .heading: ACCESSKIT_ROLE_HEADING
        case .image: ACCESSKIT_ROLE_IMAGE
        case .group: ACCESSKIT_ROLE_GROUP
        case .list: ACCESSKIT_ROLE_LIST
        case .listItem: ACCESSKIT_ROLE_LIST_ITEM
        case .tabList: ACCESSKIT_ROLE_TAB_LIST
        case .tab: ACCESSKIT_ROLE_TAB
        case .menu: ACCESSKIT_ROLE_MENU
        case .menuItem: ACCESSKIT_ROLE_MENU_ITEM
        case .textInput: ACCESSKIT_ROLE_TEXT_INPUT
        case .searchInput: ACCESSKIT_ROLE_SEARCH_INPUT
        case .passwordInput: ACCESSKIT_ROLE_PASSWORD_INPUT
        case .multilineTextInput: ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT
        case .dialog: ACCESSKIT_ROLE_DIALOG
        case .alertDialog: ACCESSKIT_ROLE_ALERT_DIALOG
        case .progressIndicator: ACCESSKIT_ROLE_PROGRESS_INDICATOR
        case .slider: ACCESSKIT_ROLE_SLIDER
        case .toolbar: ACCESSKIT_ROLE_TOOLBAR
        case .status: ACCESSKIT_ROLE_STATUS
        }
        return UInt8(role.rawValue)
    }
}

/// One element of the window as a screen reader meets it, with its children by identity. Bounds are in window points.
public struct AccessibilityNode: Equatable, Sendable {
    public var id: UInt64
    public var role: AccessibilityRole
    public var label: String?
    public var value: String?
    public var hint: String?
    public var isSelected: Bool?
    public var isFocusable: Bool
    public var bounds: Rect
    public var children: [UInt64]
}

/// The window's views as a screen reader's tree: the window at the root, then every visible view with a role, in drawing
/// order; a view without one lends its place to its children.
@MainActor
public enum AccessibilityTree {
    public static let rootID: UInt64 = 1

    /// The tree's nodes, root first, and the node the focus is on (the root when focus is nowhere in it).
    public static func snapshot(of window: Window, title: String) -> (nodes: [AccessibilityNode], focus: UInt64) {
        var nodes: [AccessibilityNode] = []
        let children = collect(window.contentView, into: &nodes)
        let root = AccessibilityNode(id: rootID, role: .window, label: title, isFocusable: false,
                                     bounds: Rect(origin: .zero, size: window.size), children: children)
        let focused = window.focus.focusedView.map(\.accessibilityID)
        let focus = focused.flatMap { id in nodes.contains { $0.id == id } ? id : nil } ?? rootID
        return ([root] + nodes, focus)
    }

    /// The accessible nodes at and under `view`, appended to `nodes`; returns the ones that belong to `view`'s parent.
    private static func collect(_ view: View, into nodes: inout [AccessibilityNode]) -> [UInt64] {
        guard !view.isHidden, view.alpha > 0.001 else { return [] }
        let role = view.accessibilityRole
        let children = role != .none && !view.accessibilityExposesChildren ? [] : view.subviews.flatMap { collect($0, into: &nodes) }
        guard role != .none else { return children }
        nodes.append(AccessibilityNode(id: view.accessibilityID, role: role, label: view.accessibilityLabel, value: view.accessibilityValue,
                                       hint: view.accessibilityHint, isSelected: view.accessibilityIsSelected,
                                       isFocusable: view.canBecomeFocused, bounds: view.frameInWindow, children: children))
        return [view.accessibilityID]
    }
}
