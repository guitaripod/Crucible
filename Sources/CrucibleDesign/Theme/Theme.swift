import UIKit

package enum Theme {
    package enum Color {
        package static let canvas = dynamic(dark: 0x181818, light: 0xF4F2EF)
        package static let surface = dynamic(dark: 0x232221, light: 0xFFFFFF)
        package static let surfaceRaised = dynamic(dark: 0x2D2B29, light: 0xEBE8E3)
        package static let surfaceHigh = dynamic(dark: 0x3A3734, light: 0xDCD8D2)

        package static let separator = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.09)
                : UIColor.black.withAlphaComponent(0.09)
        }

        package static let label = dynamic(dark: 0xF6F3EF, light: 0x1A1816)

        package static let labelSecondary = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: 0xF6F3EF).withAlphaComponent(0.68)
                : UIColor(hex: 0x1A1816).withAlphaComponent(0.72)
        }

        package static let labelTertiary = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: 0xF6F3EF).withAlphaComponent(0.52)
                : UIColor(hex: 0x1A1816).withAlphaComponent(0.62)
        }

        package static let accent = dynamic(dark: 0xFF9F0A, light: 0xFF9500)
        package static let accentText = dynamic(dark: 0xFF9F0A, light: 0xA85800)
        package static let onAccent = UIColor(hex: 0x1B1204)
        package static let accentTint = accent.withAlphaComponent(0.16)

        package static let destructive = UIColor.systemRed
        package static let statusOK = UIColor.systemGreen

        package static let onArt = UIColor.white
        package static let onArtSecondary = UIColor.white.withAlphaComponent(0.78)
        package static let onArtMuted = UIColor.white.withAlphaComponent(0.85)
        package static let artHairline = UIColor.white.withAlphaComponent(0.10)

        package static let emberTop = UIColor(hex: 0x2B1708)
        package static let emberMid = UIColor(hex: 0x6E3510)
        package static let emberBottom = UIColor(hex: 0xC96A14)
        package static let emberEyebrow = UIColor(hex: 0xFFD08A)

        /// Six steps for a heat strip drawn on the ember gradient (index 0 is an empty day).
        package static let emberStripRamp: [UIColor] = [
            onArt.withAlphaComponent(0.14),
            UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.38),
            UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.56),
            UIColor(red: 1, green: 0.75, blue: 0.35, alpha: 0.76),
            UIColor(red: 1, green: 0.78, blue: 0.43, alpha: 0.92),
            UIColor(hex: 0xFFE0A6),
        ]

        private static func dynamic(dark: UInt32, light: UInt32) -> UIColor {
            UIColor { trait in
                UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
            }
        }
    }

    package static let accent = Color.accent
    package static let accentSubtle = Color.accentTint
}

extension UIColor {
    package convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
