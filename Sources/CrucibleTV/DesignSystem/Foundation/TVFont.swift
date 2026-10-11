import CrucibleDesign
import UIKit

/// The named font recipes of the tvOS UI. Screens reference these instead of calling
/// `Theme.Font.scaled` with literal sizes, so the same role has the same size and the same Dynamic
/// Type ceiling everywhere.
@MainActor
enum TVFont {
    /// Button labels, row titles and short control text: callout 31 semibold.
    static var control: UIFont { Theme.Font.scaled(.callout, 31, .semibold, maximum: 44) }

    static var rowTitle: UIFont { control }

    /// Card titles and chip labels: body 29 semibold.
    static var cardTitle: UIFont { Theme.Font.scaled(.body, 29, .semibold, maximum: 40) }

    static var cardSubtitle: UIFont { Theme.Font.scaled(.caption1, 25, .regular, maximum: 34) }

    static var eyebrow: UIFont { Theme.Font.scaled(.caption2, 23, .bold, maximum: 31) }

    /// Fixed-size monospaced text (pairing codes, log lines); it does not scale with Dynamic Type.
    static func mono(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Forwards to `TVFont`; kept until every screen has moved to the new names.
@MainActor
enum TVCardTypography {
    static var title: UIFont { TVFont.cardTitle }
    static var subtitle: UIFont { TVFont.cardSubtitle }
    static var eyebrow: UIFont { TVFont.eyebrow }
}
