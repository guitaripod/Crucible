import UIKit
#if os(iOS)
import os

extension Theme {
    /// The reader's text size where the app has to keep it itself. On a Mac the system scales text only for Apple's own
    /// apps: an iPad app gets the large category whatever System Settings say, and every text style API (`UIFontMetrics`,
    /// `preferredFont`, a trait override) answers at that one size. There the app keeps the size the reader picks and grows
    /// each font on its text style's own Dynamic Type curve, so type keeps the proportions it has on an iPad.
    package enum TextSize {
        package static let steps: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge,
        ]
        package static let standard = UIContentSizeCategory.large

        package static var isAppControlled: Bool { ProcessInfo.processInfo.isiOSAppOnMac }

        private static let defaultsKey = "textSizeCategory"
        private static let state = OSAllocatedUnfairLock(initialState: State(category: stored()))

        /// The size the reader picked; `standard` until they pick one, and always `standard` off a Mac.
        package static var category: UIContentSizeCategory {
            get { state.withLock { $0.category } }
            set {
                let category = steps.contains(newValue) ? newValue : standard
                state.withLock { $0.category = category }
                UserDefaults.standard.set(category.rawValue, forKey: defaultsKey)
            }
        }

        /// `base` grown from its large size to `category` on the curve of `style`, kept within `maximum` points.
        static func font(_ base: UIFont, style: UIFont.TextStyle, maximum: CGFloat?) -> UIFont {
            let spec = Spec(style: style, base: base, maximum: maximum)
            let font = spec.font(at: category)
            state.withLock { $0.specs[Key(font)] = spec }
            return font
        }

        /// A length that grows with text of `style`, as `UIFontMetrics.scaledValue(for:)` does where the system scales text.
        package static func scaledValue(_ value: CGFloat, style: UIFont.TextStyle = .body) -> CGFloat {
            guard isAppControlled else { return UIFontMetrics(forTextStyle: style).scaledValue(for: value) }
            return value * ratio(style, category)
        }

        /// A system font at its large size (a default list or button font) at the reader's size, when it names its text style.
        package static func resized(_ font: UIFont) -> UIFont {
            guard isAppControlled, let style = style(of: font) else { return font }
            return font.withSize(font.pointSize * ratio(style, category))
        }

        /// `font`, made while the reader's size was `old`, as it is at the current size: a font this theme made is made
        /// again from what it was made of, a system text style font is grown along its curve, anything else is left alone.
        package static func rescaled(_ font: UIFont, from old: UIContentSizeCategory) -> UIFont? {
            if let spec = state.withLock({ $0.specs[Key(font)] }) {
                return spec.font(at: category)
            }
            guard let style = style(of: font) else { return nil }
            return font.withSize(font.pointSize * ratio(style, category) / ratio(style, old))
        }

        private static func style(of font: UIFont) -> UIFont.TextStyle? {
            (font.fontDescriptor.object(forKey: .textStyle) as? String).map(UIFont.TextStyle.init(rawValue:))
        }

        private static func stored() -> UIContentSizeCategory {
            guard isAppControlled, let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return standard }
            let category = UIContentSizeCategory(rawValue: raw)
            return steps.contains(category) ? category : standard
        }

        /// How much bigger text of `style` is at `category` than at the large size, from Apple's Dynamic Type size table.
        static func ratio(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory) -> CGFloat {
            let sizes = curve(style)
            let index = steps.firstIndex(of: category) ?? steps.firstIndex(of: standard)!
            return sizes[index] / sizes[steps.firstIndex(of: standard)!]
        }

        /// Point sizes of `style` from extra small to the largest accessibility size, as iOS sets them.
        private static func curve(_ style: UIFont.TextStyle) -> [CGFloat] {
            switch style {
            case .largeTitle: return [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60]
            case .title1: return [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]
            case .title2: return [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56]
            case .title3: return [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55]
            case .callout: return [13, 14, 15, 16, 18, 20, 22, 26, 32, 38, 44, 51]
            case .subheadline: return [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49]
            case .footnote: return [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44]
            case .caption1: return [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43]
            case .caption2: return [11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40]
            default: return [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]
            }
        }

        private struct State: @unchecked Sendable {
            var category: UIContentSizeCategory
            var specs: [Key: Spec] = [:]
        }

        /// What a theme font was made of, so it can be made again at another size.
        private struct Spec {
            let style: UIFont.TextStyle
            let base: UIFont
            let maximum: CGFloat?

            func font(at category: UIContentSizeCategory) -> UIFont {
                let size = base.pointSize * TextSize.ratio(style, category)
                return base.withSize(maximum.map { min(size, $0) } ?? size)
            }
        }

        /// Tells fonts apart by everything that draws differently, so a font on screen finds the spec it was made from.
        private struct Key: Hashable {
            let name: String
            let size: CGFloat
            let weight: CGFloat
            let traits: UInt32

            init(_ font: UIFont) {
                let descriptor = font.fontDescriptor
                let traitTable = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
                name = font.fontName
                size = font.pointSize
                weight = (traitTable?[.weight] as? CGFloat) ?? 0
                traits = descriptor.symbolicTraits.rawValue
            }
        }
    }
}

#endif

extension UIListContentConfiguration {
    /// This configuration with its default text and secondary text at the reader's size on a Mac (see `Theme.TextSize`).
    package func textSized() -> UIListContentConfiguration {
        #if os(iOS)
        guard Theme.TextSize.isAppControlled else { return self }
        var content = self
        content.textProperties.font = Theme.TextSize.resized(textProperties.font)
        content.secondaryTextProperties.font = Theme.TextSize.resized(secondaryTextProperties.font)
        return content
        #else
        return self
        #endif
    }
}
