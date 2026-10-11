import CrucibleDesign
import UIKit

/// tvOS-only colours. Everything else comes from `Theme.Color`.
enum TVColor {
    /// Fill of a focused list row: the light "lifted" plate tvOS uses in both appearances.
    static let focusFill = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xF6F3EF) : UIColor.white
    }

    /// Text and icons on `focusFill`; constant, because the fill is light in both appearances.
    static let onFocusFill = UIColor(hex: 0x1A1816)

    static let onFocusFillSecondary = UIColor(hex: 0x1A1816).withAlphaComponent(0.66)
}
