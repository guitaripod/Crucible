import Foundation
import Kiln

/// How big the Apple TV design is drawn: at a desk (the default) the tvOS layout at 60%, so body text lands on the
/// iPad's 17 points and a wide window shows more of the same shelves; on a couch the tvOS numbers one to one on a
/// 1920 by 1080 canvas scaled to the screen.
public enum Density: Sendable {
    case desk, couch

    public var factor: Float {
        switch self {
        case .desk: 0.6
        case .couch: 1
        }
    }
}

/// Every number of the design, in points: `TVMetrics` and `Theme` values from the Apple TV app, scaled by the density.
@MainActor
public struct Metrics {
    public let density: Density
    /// Ctrl with the wheel (or plus and minus) makes cards larger or smaller, as the iPad's Command plus and minus do.
    public let cardZoom: Float

    public init(density: Density = .desk, cardZoom: Float = 1) {
        self.density = density
        self.cardZoom = min(max(cardZoom, 0.7), 1.6)
    }

    private var k: Float { density.factor }

    /// `points` on the tvOS canvas at this density, on whole points.
    public func tv(_ points: Float) -> Float { (points * k).rounded() }

    private func card(_ points: Float) -> Float { (points * k * cardZoom).rounded() }

    public var topInset: Float { tv(60) }
    public var gutter: Float { tv(40) }
    public var gridRowSpacing: Float { tv(50) }
    public var sideMargin: Float { tv(80) }
    public var shelfTopInset: Float { tv(24) }
    public var shelfBottomInset: Float { tv(64) }
    public var shelfHeaderHeight: Float { tv(84) }
    public var sectionSpacing: Float { tv(24) }
    /// Room a page leaves at its top: below the floating tab bar on a couch, a margin beside the sidebar on a desk.
    public var tabBarClearance: Float { density == .desk ? tv(70) : tv(150) }

    public var formColumn: Float { tv(1000) }
    public var wideColumn: Float { tv(1100) }
    public var messageColumn: Float { tv(900) }

    public enum Space {
        public static let xxs: Float = 8
        public static let xs: Float = 16
        public static let s: Float = 24
        public static let m: Float = 32
        public static let l: Float = 48
        public static let xl: Float = 64
    }

    public func space(_ tvPoints: Float) -> Float { tv(tvPoints) }

    public var radiusXS: Float { tv(10) }
    public var radiusS: Float { tv(16) }
    public var radiusM: Float { tv(24) }
    public var radiusL: Float { tv(32) }
    public var radiusHero: Float { tv(40) }

    public var focusScale: Float { 1.04 }
    public var pressedScale: Float { 0.98 }
    public var focusShadowRadius: Float { tv(32) }
    public var focusShadowOffset: Float { tv(20) }
    public var focusShadowOpacity: Float { 0.4 }

    /// The system focus effect on artwork: tvOS enlarges a focused image by about a tenth and floats it on a deep shadow.
    public var artworkFocusScale: Float { 1.1 }

    public var posterSize: Size { Size(width: card(260), height: card(390)) }
    public var landscapeSize: Size { Size(width: card(410), height: card(230)) }
    public var personDiameter: Float { card(200) }
    public var genreSize: Size { Size(width: card(340), height: card(190)) }
    public var libraryTileSize: Size { Size(width: card(410), height: card(230)) }
    public var captionSpacing: Float { tv(16) }
    public var captionLabelSpacing: Float { tv(2) }
    public var cardCornerRadius: Float { radiusS }
    public var watchedDimming: Float { 0.55 }
    public var badgeInset: Float { tv(14) }
    public var artCaptionSpacing: Float { tv(8) }
    public var dotDiameter: Float { tv(20) }
    public var checkDiameter: Float { tv(40) }

    public var heroHeight: Float { tv(420) }
    public var heroTextColumn: Float { tv(900) }
    public var heroBlockSpacing: Float { tv(14) }
    public var heroTopClearance: Float { tv(100) }
    public var heroBottomClearance: Float { tv(36) }

    public var primaryControlHeight: Float { tv(88) }
    public var chipHeight: Float { tv(66) }
    public var controlInset: Float { tv(40) }
    public var chipInset: Float { tv(32) }
    public var plainControlHeight: Float { tv(56) }
    public var plainControlInset: Float { tv(20) }

    public var rowHeight: Float { tv(84) }
    public var rowSpacing: Float { tv(6) }
    public var rowIconWell: Float { tv(56) }
    public var rowInset: Float { tv(28) }
    public var rowFocusGrowth: Float { tv(20) }

    public var backdropTopScrim: Float { tv(220) }
    public var backdropMaximumDimming: Float { 0.82 }

    public var symbolRow: Float { tv(30) }
    public var symbolAccessory: Float { tv(26) }
    public var symbolTile: Float { tv(44) }
    public var symbolBadge: Float { tv(18) }
    public var symbolState: Float { tv(80) }

    public var progressBarThickness: Float { tv(8) }
    public var badgeInsetHorizontal: Float { tv(14) }
    public var badgeInsetVertical: Float { tv(6) }

    /// Tab bar geometry: the bar floats 46 to 114 points down the tvOS canvas.
    public var tabBarTop: Float { tv(46) }
    public var tabBarHeight: Float { tv(68) }
    public var tabItemInset: Float { tv(28) }

    /// The grid's column count for cards `itemWidth` wide across `width`, with the gutter between them.
    public func gridColumns(itemWidth: Float, width: Float) -> Int {
        max(1, Int(((width + gutter) / (itemWidth + gutter)).rounded()))
    }

    /// The row scale that grows a view `width` points wide by `rowFocusGrowth` at each side, never past `focusScale`.
    public func rowScale(width: Float) -> Float {
        guard width > 0 else { return focusScale }
        return min(focusScale, 1 + 2 * rowFocusGrowth / width)
    }

    /// Pixel width to request for an image shown `points` wide, with room for the focus enlargement.
    public func imagePixelWidth(points: Float, scale: Float) -> Int {
        Int((points * max(scale, 1) * 1.1).rounded(.up))
    }
}

/// The type recipes of the tvOS UI (`Theme.Font`, `TVFont`) at the density's size.
@MainActor
public struct TypeScale {
    let metrics: Metrics
    /// The desktop's text size, as Dynamic Type scales the Apple TV's recipes, under the ceiling `Theme.textScale` keeps.
    var textScale: Float = 1

    private func font(_ tvSize: Float, _ weight: Font.Weight) -> Font {
        Font(size: (tvSize * metrics.density.factor * textScale * 2).rounded() / 2, weight: weight)
    }

    public var largeTitle: Font { font(76, .bold) }
    public var title1: Font { font(76, .bold) }
    public var title2: Font { font(57, .bold) }
    public var title3: Font { font(48, .semibold) }
    public var headline: Font { font(38, .semibold) }
    public var body: Font { font(29, .regular) }
    public var callout: Font { font(31, .regular) }
    public var subheadline: Font { font(35, .regular) }
    public var footnote: Font { font(23, .regular) }
    public var caption1: Font { font(25, .semibold) }
    public var caption2: Font { font(23, .bold) }
    public var badge: Font { font(23, .bold) }

    /// Button labels, row titles and short control text.
    public var control: Font { font(31, .semibold) }
    public var rowTitle: Font { control }
    /// Card titles and chip labels.
    public var cardTitle: Font { font(29, .semibold) }
    public var cardSubtitle: Font { font(25, .regular) }
    public var eyebrow: Font { font(23, .bold) }
    /// The time left or runtime on a card's artwork, above its progress bar.
    public var artCaption: Font { font(23, .semibold) }
    public var screenTitle: Font { title2 }
    public var screenSummary: Font { callout }
    public var screenDetail: Font { body }
    /// The text typed into the Search field.
    public var searchField: Font { Font(size: title3.size * 0.85, weight: .medium) }

    /// Every recipe, for warming the fonts at launch.
    public var all: [Font] {
        [largeTitle, title2, title3, headline, body, callout, subheadline, footnote, caption1, caption2, control, cardTitle, cardSubtitle,
         eyebrow, artCaption, searchField]
    }
}

/// `Theme.Color` and `TVColor` in both appearances.
public struct Palette: Sendable {
    public enum Appearance: Sendable { case dark, light }

    public let appearance: Appearance
    public let canvas: Color
    public let surface: Color
    public let surfaceRaised: Color
    public let surfaceHigh: Color
    public let separator: Color
    public let label: Color
    public let labelSecondary: Color
    public let labelTertiary: Color
    public let accent: Color
    public let accentText: Color
    public let onAccent = Color(hex: 0x1B1204)
    public let destructive: Color
    public let statusOK: Color
    public let onArt = Color.white
    public let onArtSecondary = Color.white.withSRGBAlpha(0.78)
    public let onArtMuted = Color.white.withSRGBAlpha(0.85)
    public let artHairline = Color.white.withSRGBAlpha(0.10)
    public let focusFill: Color
    public let onFocusFill = Color(hex: 0x1A1816)
    public let onFocusFillSecondary = Color(hex: 0x1A1816, srgbAlpha: 0.66)
    public let emberTop = Color(hex: 0x2B1708)
    public let emberMid = Color(hex: 0x6E3510)
    public let emberBottom = Color(hex: 0xC96A14)
    public let emberEyebrow = Color(hex: 0xFFD08A)

    public var accentTint: Color { accent.withSRGBAlpha(0.16) }

    /// The warm glow behind the welcome screen's crystal: ember dark on the dark canvas, a soft amber on the light one.
    public var welcomeGlow: Color {
        appearance == .dark ? Color(srgbRed: 0.18, green: 0.10, blue: 0.04).withAlpha(0.95) : Color(srgbRed: 1.0, green: 0.84, blue: 0.62).withAlpha(0.55)
    }

    public static let dark = Palette(
        appearance: .dark,
        canvas: Color(hex: 0x181818),
        surface: Color(hex: 0x232221),
        surfaceRaised: Color(hex: 0x2D2B29),
        surfaceHigh: Color(hex: 0x3A3734),
        separator: Color.white.withSRGBAlpha(0.09),
        label: Color(hex: 0xF6F3EF),
        labelSecondary: Color(hex: 0xF6F3EF, srgbAlpha: 0.68),
        labelTertiary: Color(hex: 0xF6F3EF, srgbAlpha: 0.52),
        accent: Color(hex: 0xFF9F0A),
        accentText: Color(hex: 0xFF9F0A),
        destructive: Color(hex: 0xFF453A),
        statusOK: Color(hex: 0x30D158),
        focusFill: Color(hex: 0xF6F3EF)
    )

    public static let light = Palette(
        appearance: .light,
        canvas: Color(hex: 0xF4F2EF),
        surface: Color(hex: 0xFFFFFF),
        surfaceRaised: Color(hex: 0xEBE8E3),
        surfaceHigh: Color(hex: 0xDCD8D2),
        separator: Color.black.withSRGBAlpha(0.09),
        label: Color(hex: 0x1A1816),
        labelSecondary: Color(hex: 0x1A1816, srgbAlpha: 0.72),
        labelTertiary: Color(hex: 0x1A1816, srgbAlpha: 0.62),
        accent: Color(hex: 0xFF9500),
        accentText: Color(hex: 0xA85800),
        destructive: Color(hex: 0xFF3B30),
        statusOK: Color(hex: 0x34C759),
        focusFill: Color.white
    )
}

/// The design's state for one window: density, card zoom, appearance and transparency. Views read it through
/// `Theme.current` and are laid out again when it changes.
@MainActor
public final class Theme {
    public static var current = Theme()

    public var density: Density = .desk { didSet { notify() } }
    public var cardZoom: Float = 1 { didSet { notify() } }
    public var palette: Palette = .dark { didSet { notify() } }
    /// Reduce Transparency: glass becomes the opaque raised surface.
    public var reduceTransparency = false { didSet { notify() } }
    /// The desktop's text scaling, from 1 to `maximumTextScale`, applied to the type recipes.
    public var textScale: Float = 1 { didSet { notify() } }
    public static let maximumTextScale: Float = 1.3

    public var metrics: Metrics { Metrics(density: density, cardZoom: cardZoom) }
    public var type: TypeScale { TypeScale(metrics: metrics, textScale: min(max(textScale, 1), Self.maximumTextScale)) }

    private var observers: [(id: ObjectIdentifier, handler: @MainActor () -> Void)] = []

    public init() {}

    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append((ObjectIdentifier(owner), handler))
    }

    public func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.id == ObjectIdentifier(owner) }
    }

    private func notify() {
        Font.opticalScale = density == .couch ? 0.6 : 1
        for observer in observers { observer.handler() }
    }
}

/// The tvOS durations (`TVMetrics.Duration`).
public enum Durations {
    public static let focus: Float = 0.2
    public static let fade: Float = 0.25
    public static let heroText: Float = 0.25
    public static let heroReturn: Float = 0.35
    public static let backdropFade: Float = 0.35
    public static let backdropDebounce: Double = 0.4
    public static let skeletonPulse: Float = 1.2
}

/// The design system's own strings ("See All", "Previous"), looked up in the app's catalog once the app installs it.
@MainActor
public enum Strings {
    public static var lookup: (String) -> String = { $0 }

    public static func text(_ key: String) -> String { lookup(key) }
}
