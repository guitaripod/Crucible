import Foundation

extension GPU {
    /// `texture` heavily blurred into a new half-size texture by the frost pyramid's dual-Kawase passes (a poster washed
    /// across a page). The texels stay encoded as the source's were, so an 8-bit sRGB source is drawn with `srgb: true`.
    public func blurred(_ texture: Texture, spread: Float = 1.6) -> Texture? {
        guard texture.width >= 16, texture.height >= 16,
              let pyramid = try? LiquidGlassRenderer(gpu: self, width: texture.width, height: texture.height) else { return nil }
        pyramid.blur(texture, spread: spread)
        return pyramid.frost
    }
}
