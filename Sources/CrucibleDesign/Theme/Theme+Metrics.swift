import UIKit

extension Theme {
    /// Resolves a token to its phone or Apple TV value. Every platform-specific metric in the design
    /// system funnels through here, so the rest of the module never branches on the platform.
    private static func metric<Value>(phone: Value, tv: Value) -> Value {
        #if os(tvOS)
        return tv
        #else
        return phone
        #endif
    }

    /// tvOS has no large-title text style, so its 76pt title scales with the title1 curve.
    private static var largeTitleStyle: UIFont.TextStyle {
        #if os(tvOS)
        return .title1
        #else
        return .largeTitle
        #endif
    }

    package enum Font {
        package static var largeTitle: UIFont { scaled(largeTitleStyle, metric(phone: 34, tv: 76), .bold) }
        package static var title1: UIFont { scaled(.title1, metric(phone: 28, tv: 76), .bold) }
        package static var title2: UIFont { scaled(.title2, metric(phone: 22, tv: 57), .bold) }
        package static var title3: UIFont { scaled(.title3, metric(phone: 20, tv: 48), .semibold) }
        package static var headline: UIFont { scaled(.headline, metric(phone: 17, tv: 38), .semibold) }
        package static var body: UIFont { scaled(.body, metric(phone: 17, tv: 29), .regular) }
        package static var callout: UIFont { scaled(.callout, metric(phone: 16, tv: 31), .regular) }
        package static var subheadline: UIFont { scaled(.subheadline, metric(phone: 15, tv: 35), .regular) }
        package static var subheadlineSemibold: UIFont { scaled(.subheadline, metric(phone: 15, tv: 35), .semibold) }
        package static var footnote: UIFont { scaled(.footnote, metric(phone: 13, tv: 23), .regular) }
        package static var footnoteSemibold: UIFont { scaled(.footnote, metric(phone: 13, tv: 23), .semibold) }
        package static var caption1: UIFont { scaled(.caption1, metric(phone: 12, tv: 25), .semibold) }
        package static var caption1Regular: UIFont { scaled(.caption1, metric(phone: 12, tv: 25), .regular) }
        package static var caption2: UIFont { scaled(.caption2, metric(phone: 11, tv: 23), .bold) }
        package static var caption2Regular: UIFont { scaled(.caption2, metric(phone: 11, tv: 23), .regular) }
        package static var buttonLabel: UIFont {
            scaled(.headline, metric(phone: 17, tv: 38), .semibold, maximum: metric(phone: 24, tv: 52))
        }
        package static var badge: UIFont {
            scaled(.caption2, metric(phone: 11, tv: 23), .bold, maximum: metric(phone: 15, tv: 31))
        }
        package static var monogram: UIFont {
            scaled(.title1, metric(phone: 24, tv: 76), .bold, maximum: metric(phone: 30, tv: 90))
        }

        package static func scaled(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight, maximum: CGFloat? = nil) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let metrics = UIFontMetrics(forTextStyle: style)
            if let maximum {
                return metrics.scaledFont(for: base, maximumPointSize: maximum)
            }
            return metrics.scaledFont(for: base)
        }
    }

    package enum Space {
        package static let xxs: CGFloat = metric(phone: 4, tv: 8)
        package static let xs: CGFloat = metric(phone: 8, tv: 16)
        package static let s: CGFloat = metric(phone: 12, tv: 24)
        package static let m: CGFloat = metric(phone: 16, tv: 32)
        package static let l: CGFloat = metric(phone: 24, tv: 48)
        package static let xl: CGFloat = metric(phone: 32, tv: 64)
    }

    package enum Radius {
        package static let xs: CGFloat = metric(phone: 6, tv: 10)
        package static let s: CGFloat = metric(phone: 10, tv: 16)
        package static let m: CGFloat = metric(phone: 16, tv: 24)
        package static let l: CGFloat = metric(phone: 24, tv: 32)
        package static let hero: CGFloat = metric(phone: 28, tv: 40)
    }

    /// Dimensions of the shared atoms (progress bar, badge chip) that scale with the platform.
    package enum Metric {
        package static let progressBarThickness: CGFloat = metric(phone: 4, tv: 8)
        package static let badgeBorderWidth: CGFloat = metric(phone: 1, tv: 2)
        package static let badgeInsetHorizontal: CGFloat = metric(phone: 7, tv: 14)
        package static let badgeInsetVertical: CGFloat = metric(phone: 3, tv: 6)
        package static let monogramDiameter: CGFloat = metric(phone: 56, tv: 150)
        package static let monogramBorderWidth: CGFloat = metric(phone: 1, tv: 2)
    }
}
