import Foundation

/// What a view draws with: Kiln's primitives in the view's own points, mapped to target pixels by the composed transform,
/// faded by the composed alpha and clipped by the composed clip.
@MainActor
public struct DrawContext {
    let renderer: SceneRenderer
    /// The view's points to target pixels.
    public internal(set) var transform: Affine
    /// The product of every ancestor's alpha.
    public internal(set) var alpha: Float
    /// Target pixels outside are left alone.
    public internal(set) var clip: Rect?

    /// Target pixels per point at rest: the window's scale (text is rasterised at this).
    public var rasterScale: Float { renderer.scale }

    /// Pixels per point as drawn, including lifts.
    public var pixelScale: Float { transform.scale }

    init(renderer: SceneRenderer, transform: Affine, alpha: Float, clip: Rect?) {
        self.renderer = renderer
        self.transform = transform
        self.alpha = alpha
        self.clip = clip
    }

    private func applyClip() {
        renderer.painter.clip = clip
    }

    public func fill(_ rect: Rect, radius: Float = 0, color: Color) {
        applyClip()
        renderer.painter.fill(transform.apply(rect), radius: radius * transform.scale, color: color.multipliedAlpha(alpha))
    }

    public func stroke(_ rect: Rect, radius: Float = 0, width: Float, color: Color) {
        applyClip()
        renderer.painter.stroke(transform.apply(rect), radius: radius * transform.scale, width: width * transform.scale,
                                color: color.multipliedAlpha(alpha))
    }

    public func shadow(_ rect: Rect, radius: Float, blur: Float, offsetY: Float, opacity: Float, color: Color = .black) {
        applyClip()
        renderer.painter.shadow(transform.apply(rect), radius: radius * transform.scale, blur: blur * transform.scale,
                                offsetY: offsetY * transform.scale, opacity: opacity * alpha, color: color)
    }

    public func image(_ texture: Texture, in rect: Rect, radius: Float = 0, opacity: Float = 1, srgb: Bool? = nil, fit: Bool = false,
                      circle: Bool = false) {
        applyClip()
        renderer.painter.image(texture, in: transform.apply(rect), radius: radius * transform.scale, opacity: opacity * alpha, srgb: srgb,
                               fit: fit, circle: circle)
    }

    public func gradient(_ rect: Rect, vertical: Bool, stops: [(position: Float, color: Color)], radius: Float = 0) {
        applyClip()
        let faded = stops.map { (position: $0.position, color: $0.color.multipliedAlpha(alpha)) }
        renderer.painter.gradient(transform.apply(rect), vertical: vertical, stops: faded, radius: radius * transform.scale)
    }

    public func glow(in rect: Rect, radius: Float, center: Point, glowRadius: Float, color: Color) {
        applyClip()
        renderer.painter.glow(in: transform.apply(rect), radius: radius * transform.scale, center: transform.apply(center),
                              glowRadius: glowRadius * transform.scale, color: color.multipliedAlpha(alpha))
    }

    /// Draws `layout` with its top left at `origin`.
    public func text(_ layout: TextLayout, at origin: Point, color: Color) {
        guard let texture = layout.texture(renderer: renderer.text) else { return }
        applyClip()
        let placed = transform.apply(Rect(origin: origin, size: layout.size))
        let pixelWidth = Float(texture.width) * transform.scale / renderer.scale
        let pixelHeight = Float(texture.height) * transform.scale / renderer.scale
        renderer.painter.mask(texture, in: Rect(x: placed.x, y: placed.y, width: pixelWidth, height: pixelHeight), color: color.multipliedAlpha(alpha))
    }

    /// A coverage texture (a QR code, a mark) tinted into `rect`; `nearest` keeps hard module edges when scaled.
    public func mask(_ texture: Texture, in rect: Rect, color: Color, nearest: Bool = false) {
        applyClip()
        renderer.painter.mask(texture, in: transform.apply(rect), color: color.multipliedAlpha(alpha), nearest: nearest)
    }

    /// Draws a symbol's mask into `rect`, tinted.
    public func symbol(_ symbol: Symbol, in rect: Rect, color: Color) {
        let pixels = transform.apply(rect)
        guard let texture = renderer.symbols.texture(for: symbol, pixelSize: Int((max(rect.width, rect.height) * renderer.scale).rounded())) else { return }
        applyClip()
        let side = max(pixels.width, pixels.height)
        renderer.painter.mask(texture, in: Rect(x: pixels.midX - side / 2, y: pixels.midY - side / 2, width: side, height: side),
                              color: color.multipliedAlpha(alpha))
    }

    /// The mean luminance (linear, 1.0 = reference white) of what lies under `rect` (this view's points), a frame or two
    /// late; nil until the first glass has been drawn.
    public func backdropLuminance(of rect: Rect) -> Float? {
        renderer.backdropLuminance(in: transform.apply(rect))
    }

    /// Liquid Glass over everything drawn so far, with its shapes in this view's points.
    public func glass(_ element: LiquidGlass) {
        renderer.drawGlass(element.transformed(by: transform), clip: clip, opacity: alpha)
    }

    /// Runs `body` with drawing clipped to `rect` (in this view's points) as well.
    public func clipped(to rect: Rect, _ body: (inout DrawContext) -> Void) {
        var inner = self
        let pixels = transform.apply(rect)
        inner.clip = clip.map { $0.intersection(pixels) } ?? pixels
        body(&inner)
    }

    /// Runs `body` with the drawing translated and scaled about `pivot`.
    public func transformed(scale: Float, about pivot: Point, translation: Point = .zero, _ body: (inout DrawContext) -> Void) {
        var inner = self
        let local = Affine(scale: scale, tx: pivot.x - scale * pivot.x + translation.x, ty: pivot.y - scale * pivot.y + translation.y)
        inner.transform = transform.concatenating(local)
        body(&inner)
    }

    /// Runs `body` with its drawing faded by `opacity`.
    public func faded(_ opacity: Float, _ body: (inout DrawContext) -> Void) {
        var inner = self
        inner.alpha *= opacity
        body(&inner)
    }
}

extension LiquidGlass {
    func transformed(by transform: Affine) -> LiquidGlass {
        var copy = self
        func map(_ shape: Shape) -> Shape {
            let center = transform.apply(Point(x: shape.centerX, y: shape.centerY))
            return Shape(centerX: center.x, centerY: center.y, halfWidth: shape.halfWidth * transform.scale,
                         halfHeight: shape.halfHeight * transform.scale, radius: shape.radius * transform.scale)
        }
        copy.primary = map(primary)
        copy.secondary = secondary.map(map)
        copy.pill = pill.map(map)
        let light = transform.apply(Point(x: lightX, y: lightY))
        copy.lightX = light.x
        copy.lightY = light.y
        copy.blend *= transform.scale
        copy.rimWidth *= transform.scale
        copy.refraction *= transform.scale
        copy.shadowOffsetY *= transform.scale
        copy.shadowRadius *= transform.scale
        return copy
    }

    /// The pixels the element and its shadow can touch.
    var bounds: Rect {
        func rect(_ shape: Shape) -> Rect {
            Rect(x: shape.centerX - shape.halfWidth, y: shape.centerY - shape.halfHeight, width: shape.halfWidth * 2, height: shape.halfHeight * 2)
        }
        var area = rect(primary)
        if let secondary { area = area.union(rect(secondary)) }
        let reach = shadowRadius * 1.5 + abs(shadowOffsetY) + blend + 2
        return area.insetBy(-reach, -reach)
    }
}
