import Foundation

/// A colour in Kiln's composition space: linear BT.709 with straight alpha, where 1.0 is the UI's reference white.
public struct Color: Hashable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(linearRed red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A design-token colour given as sRGB hex (`0xFF9F0A`), linearised.
    public init(hex: UInt32, alpha: Float = 1) {
        red = Self.linear(Float((hex >> 16) & 0xFF) / 255)
        green = Self.linear(Float((hex >> 8) & 0xFF) / 255)
        blue = Self.linear(Float(hex & 0xFF) / 255)
        self.alpha = alpha
    }

    /// A colour given as sRGB components from 0 to 1, as UIKit's `UIColor(red:green:blue:alpha:)` takes them.
    public init(srgbRed red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = Self.linear(red)
        self.green = Self.linear(green)
        self.blue = Self.linear(blue)
        self.alpha = alpha
    }

    private static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : Float(pow(Double((value + 0.055) / 1.055), 2.4))
    }

    public func withAlpha(_ alpha: Float) -> Color {
        Color(linearRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func multipliedAlpha(_ factor: Float) -> Color {
        Color(linearRed: red, green: green, blue: blue, alpha: alpha * factor)
    }

    /// Relative luminance in linear light (BT.709 weights).
    public var luminance: Float { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    public func mixed(with other: Color, amount: Float) -> Color {
        let t = min(max(amount, 0), 1)
        return Color(
            linearRed: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// Black at the opacity a design tool's sRGB blending gives `alpha`: Kiln blends in linear light, where the same
    /// alpha darkens far less, so scrims, shadows and dimming tuned on Apple platforms are converted to look the same.
    public static func shade(_ alpha: Float) -> Color {
        Color(linearRed: 0, green: 0, blue: 0, alpha: 1 - Float(pow(Double(1 - min(max(alpha, 0), 1)), 2.2)))
    }

    /// `self` (an opaque colour) as an overlay at `alpha` that darkens or tints as much as sRGB blending would.
    public func overlay(_ alpha: Float) -> Color {
        guard luminance < 0.05 else { return withAlpha(alpha) }
        return Color(linearRed: red, green: green, blue: blue, alpha: 1 - Float(pow(Double(1 - min(max(alpha, 0), 1)), 2.2)))
    }

    public static let white = Color(linearRed: 1, green: 1, blue: 1)
    public static let black = Color(linearRed: 0, green: 0, blue: 0)
    public static let clear = Color(linearRed: 0, green: 0, blue: 0, alpha: 0)
}
