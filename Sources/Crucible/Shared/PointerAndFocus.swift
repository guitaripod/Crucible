@preconcurrency import UIKit

extension UIView {
    /// Artwork a trackpad pointer or a hovering Apple Pencil rests on lifts toward the viewer, the way posters do across iPadOS.
    func liftsOnHover(cornerRadius: CGFloat) {
        hoverStyle = UIHoverStyle(effect: .lift, shape: .rect(cornerRadius: cornerRadius, cornerCurve: .continuous))
    }

    /// Draws the keyboard focus ring of the cell this view sits in around `card` instead of around the whole cell and its caption.
    /// Call it from `layoutSubviews`, since the ring follows the card's frame.
    func ringsFocus(around card: UIView, cornerRadius: CGFloat) {
        var ancestor = superview
        while let view = ancestor, !(view is UICollectionViewCell) {
            ancestor = view.superview
        }
        guard let cell = ancestor as? UICollectionViewCell, !card.bounds.isEmpty else { return }
        let effect = UIFocusHaloEffect(roundedRect: card.convert(card.bounds, to: cell), cornerRadius: cornerRadius, curve: .continuous)
        effect.referenceView = card
        cell.focusEffect = effect
    }
}

extension UICollectionView {
    /// Lets a hardware keyboard move through the cells with the arrow and Tab keys and open one with Return or Space, coming back to the
    /// cell it left.
    func allowsKeyboardFocus() {
        allowsFocus = true
        remembersLastFocusedIndexPath = true
    }
}

extension UIView {
    /// The safe area, stepping sideways around an iPad window's controls in the top corner (iPadOS 26) instead of pushing content down.
    var cornerAdaptiveSafeArea: UILayoutGuide {
        if #available(iOS 26.0, *) {
            return layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        }
        return safeAreaLayoutGuide
    }
}
