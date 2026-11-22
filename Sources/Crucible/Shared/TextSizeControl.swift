import CrucibleDesign
import UIKit

/// The reader's text size on a Mac, where the system leaves an iPad app's text at one size (see `Theme.TextSize`): the View
/// menu steps it, every window takes it as its content size so layouts that change for large type change with it, and
/// what is on screen follows at once.
@MainActor
enum TextSizeControl {
    static var isAvailable: Bool { Theme.TextSize.isAppControlled }

    static var canGrow: Bool { isAvailable && Theme.TextSize.category != Theme.TextSize.steps.last }
    static var canShrink: Bool { isAvailable && Theme.TextSize.category != Theme.TextSize.steps.first }
    static var isStandard: Bool { Theme.TextSize.category == Theme.TextSize.standard }

    static func grow() { step(by: 1) }
    static func shrink() { step(by: -1) }
    static func reset() { apply(Theme.TextSize.standard) }

    /// Gives a newly connected window the reader's size before anything is drawn in it.
    static func adopt(_ scene: UIWindowScene) {
        guard isAvailable else { return }
        scene.traitOverrides.preferredContentSizeCategory = Theme.TextSize.category
    }

    private static func step(by offset: Int) {
        let steps = Theme.TextSize.steps
        guard let index = steps.firstIndex(of: Theme.TextSize.category) else { return }
        apply(steps[min(max(index + offset, 0), steps.count - 1)])
    }

    private static func apply(_ category: UIContentSizeCategory) {
        let old = Theme.TextSize.category
        guard isAvailable, category != old else { return }
        Theme.TextSize.category = category
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var refresh = Refresh(old: old)
        for window in scenes.flatMap(\.windows) {
            if let root = window.rootViewController { refresh.walk(root) }
        }
        refresh.finish()
        scenes.forEach(adopt)
    }

    /// One pass over every screen that is loaded, in every window: text set once when a view was built is grown to the new
    /// size in place, buttons and lists build their content again from the theme, and layouts measure again.
    private struct Refresh {
        let old: UIContentSizeCategory
        private var visited: Set<ObjectIdentifier> = []
        private var collections: [UICollectionView] = []

        init(old: UIContentSizeCategory) {
            self.old = old
        }

        mutating func walk(_ controller: UIViewController) {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
            if Self.isOurs(controller), let view = controller.viewIfLoaded {
                walk(view, owner: controller)
            }
            controller.children.forEach { walk($0) }
            if let presented = controller.presentedViewController { walk(presented) }
        }

        func finish() {
            for collection in collections {
                collection.reloadData()
                collection.collectionViewLayout.invalidateLayout()
            }
        }

        /// UIKit's own screens (the sidebar, the player, system sheets) keep the system's text, which they reset on their own.
        private static func isOurs(_ controller: UIViewController) -> Bool {
            !Bundle(for: type(of: controller)).bundlePath.hasPrefix("/System/")
        }

        private mutating func walk(_ view: UIView, owner: UIViewController) {
            if let controller = view.next as? UIViewController, controller !== owner { return }
            switch view {
            case is UINavigationBar, is UITabBar, is UIToolbar, is UISearchBar, is UISegmentedControl:
                return
            case let button as UIButton:
                refresh(button)
                return
            case let label as UILabel:
                refresh(label)
            case let field as UITextField:
                field.font = field.font.flatMap(rescaled) ?? field.font
            case let text as UITextView:
                refresh(text)
            case let collection as UICollectionView:
                collections.append(collection)
            default:
                break
            }
            view.subviews.forEach { walk($0, owner: owner) }
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }

        private func refresh(_ label: UILabel) {
            let mixed = label.attributedText.flatMap(rescaledIfMixed)
            if let font = rescaled(label.font) { label.font = font }
            if let mixed { label.attributedText = mixed }
        }

        private func refresh(_ text: UITextView) {
            let mixed = text.attributedText.flatMap(rescaledIfMixed)
            if let font = text.font.flatMap(rescaled) { text.font = font }
            if let mixed { text.attributedText = mixed }
        }

        private func refresh(_ button: UIButton) {
            guard var configuration = button.configuration else { return }
            configuration.attributedTitle = configuration.attributedTitle.map(rescaledRuns)
            configuration.attributedSubtitle = configuration.attributedSubtitle.map(rescaledRuns)
            button.configuration = configuration
            button.setNeedsUpdateConfiguration()
        }

        private func rescaled(_ font: UIFont) -> UIFont? {
            Theme.TextSize.rescaled(font, from: old)
        }

        /// Text drawn in more than one font, grown run by run; nil when one font covers it all and setting the font is enough.
        private func rescaledIfMixed(_ text: NSAttributedString) -> NSAttributedString? {
            var fonts = Set<UIFont>()
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let font = value as? UIFont { fonts.insert(font) }
            }
            return fonts.count > 1 ? rescaledRuns(text) : nil
        }

        private func rescaledRuns(_ text: AttributedString) -> AttributedString {
            (try? AttributedString(rescaledRuns(NSAttributedString(text)), including: \.uiKit)) ?? text
        }

        private func rescaledRuns(_ text: NSAttributedString) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let font = value as? UIFont, let grown = rescaled(font) else { return }
                result.addAttribute(.font, value: grown, range: range)
            }
            return result
        }
    }
}
