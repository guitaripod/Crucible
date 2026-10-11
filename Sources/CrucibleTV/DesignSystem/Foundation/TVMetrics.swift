import CrucibleDesign
import UIKit

/// Every tvOS-only number of the design system, in points on the 1920x1080 canvas. Colours, fonts,
/// spacing and radii come from `Theme`; this file adds what only the ten-foot layout needs.
enum TVMetrics {
    static let topInset: CGFloat = 60
    static let gutter: CGFloat = 40
    static let gridRowSpacing: CGFloat = 50

    /// Room kept above a shelf's cards (between header and artwork) and below them (between the
    /// caption and the next header). The larger bottom gap keeps a header attached to its own shelf,
    /// and both leave room for a focused, enlarged card.
    static let shelfTopInset: CGFloat = 24
    static let shelfBottomInset: CGFloat = 64
    static let shelfVerticalInset: CGFloat = 40
    static let shelfHeaderHeight: CGFloat = 84
    static let sectionSpacing: CGFloat = 24

    /// Distance from the top of the screen to the first line of content on a pushed screen: the tab
    /// bar occupies 46...114pt, so this leaves a 36pt gap below it (`shelfVerticalInset` is 40, the
    /// same rhythm). Every pushed screen starts its first row at this y.
    static let tabBarClearance: CGFloat = 150

    static let imageOversample: CGFloat = 1.1

    /// Widths of centred text and form columns.
    enum Column {
        static let form: CGFloat = 1000
        static let wide: CGFloat = 1100
        static let message: CGFloat = 900
    }

    /// The focus lift of custom focusable surfaces and rows (cards use the system effect).
    enum Focus {
        static let scale: CGFloat = 1.04
        static let pressedScale: CGFloat = 0.98
        static let shadowRadius: CGFloat = 32
        static let shadowOffset = CGSize(width: 0, height: 20)
        static let shadowOpacity: Float = 0.4
    }

    /// SF Symbol point sizes that do not follow Dynamic Type.
    enum Symbol {
        static let row: CGFloat = 30
        static let accessory: CGFloat = 26
        static let tile: CGFloat = 44
        static let badge: CGFloat = 18
        static let state: CGFloat = 80
    }

    enum Dot {
        static let small: CGFloat = 16
        static let large: CGFloat = 24
    }

    enum Duration {
        static let focus: TimeInterval = 0.2
        static let fade: TimeInterval = 0.25
        static let heroText: TimeInterval = 0.25
        static let backdropFade: TimeInterval = 0.35
        static let backdropDebounce: TimeInterval = 0.4
        static let skeletonPulse: TimeInterval = 1.2
    }

    enum Card {
        static let posterSize = CGSize(width: 260, height: 390)
        static let landscapeSize = CGSize(width: 410, height: 230)
        static let personDiameter: CGFloat = 200
        static let genreSize = CGSize(width: 340, height: 190)
        static let libraryTileSize = CGSize(width: 410, height: 230)
        static let captionSpacing: CGFloat = 16
        static let captionLabelSpacing: CGFloat = 2
        static let cornerRadius: CGFloat = Theme.Radius.s
        static let watchedDimming: CGFloat = 0.55
        static let badgeInset: CGFloat = 14
        static let dotDiameter: CGFloat = 20
        static let checkDiameter: CGFloat = 40
    }

    enum Hero {
        static let height: CGFloat = 420
        static let textColumnWidth: CGFloat = Column.message
        static let synopsisLines = 3
        static let titleLines = 2
        static let blockSpacing: CGFloat = 14
        static let bottomClearance: CGFloat = 36
    }

    enum Control {
        static let primaryHeight: CGFloat = 88
        static let chipHeight: CGFloat = 66
        static let horizontalInset: CGFloat = 40
        static let chipHorizontalInset: CGFloat = 32
        static let plainHeight: CGFloat = 56
        static let plainHorizontalInset: CGFloat = 20
    }

    enum Row {
        static let height: CGFloat = 96
        static let spacing: CGFloat = 12
        static let iconWell: CGFloat = 60
        static let horizontalInset: CGFloat = 28
    }

    enum Backdrop {
        static let topScrimHeight: CGFloat = 220
        static let maximumDimming: CGFloat = 0.82
        static let maximumPixelWidth = 1920
        static let maximumPosterPixelWidth = 720
    }

    /// Pixel width to request for an image shown `points` wide, with a margin for the focus enlargement.
    static func pixelWidth(forPoints points: CGFloat, scale: CGFloat) -> Int {
        Int((points * max(scale, 1) * imageOversample).rounded(.up))
    }
}
