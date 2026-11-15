/// One glass element: up to two shapes that melt into each other when close, an optional selection pill inside, and the
/// light that plays on the rim (the pointer, the focused item or the right stick). Coordinates are target pixels with
/// the origin at the top left.
public struct LiquidGlass: Sendable {
    public struct Shape: Sendable {
        public var centerX: Float
        public var centerY: Float
        public var halfWidth: Float
        public var halfHeight: Float
        public var radius: Float

        public init(centerX: Float, centerY: Float, halfWidth: Float, halfHeight: Float, radius: Float) {
            self.centerX = centerX
            self.centerY = centerY
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
            self.radius = radius
        }
    }

    public enum Variant: Sendable { case regular, clear }

    public var primary: Shape
    public var secondary: Shape?
    public var blend: Float = 0
    public var pill: Shape?
    public var lightX: Float
    public var lightY: Float
    public var press: Float = 0
    public var variant: Variant = .regular
    public var rimWidth: Float = 14
    public var refraction: Float = 18
    public var dispersion: Float = 0.06
    public var shadowOpacity: Float = 0.28
    public var shadowOffsetY: Float = 10
    public var shadowRadius: Float = 26

    public init(primary: Shape, lightX: Float, lightY: Float) {
        self.primary = primary
        self.lightX = lightX
        self.lightY = lightY
    }
}

/// Blurs a frame into the frost pyramid and composites Liquid Glass over it in linear light, on Kiln's GPU.
@MainActor
public final class LiquidGlassRenderer {
    private let gpu: GPU
    private var downTargets: [Texture] = []
    private var upTargets: [Texture] = []

    public init(gpu: GPU, width: Int, height: Int) throws(RenderError) {
        self.gpu = gpu
        try resize(width: width, height: height)
    }

    public func resize(width: Int, height: Int) throws(RenderError) {
        downTargets = []
        upTargets = []
        var w = width
        var h = height
        for _ in 0..<4 {
            w = max(w / 2, 1)
            h = max(h / 2, 1)
            downTargets.append(try gpu.texture(width: w, height: h, format: .rgba16f, renderable: true))
        }
        for index in stride(from: downTargets.count - 2, through: 0, by: -1) {
            upTargets.append(try gpu.texture(width: downTargets[index].width, height: downTargets[index].height, format: .rgba16f, renderable: true))
        }
    }

    public var frost: Texture { upTargets.last ?? downTargets[0] }
    public var tiny: Texture { downTargets[downTargets.count - 1] }

    /// Dual-Kawase blur: four halvings, then three doublings back to half resolution.
    public func blur(_ scene: Texture, spread: Float = 1.6) {
        var source = scene
        for target in downTargets {
            gpu.pass(into: target, body: LiquidGlassShaders.kawaseDown, samplers: [.init("source", source)], uniforms: [
                .init("outputSize", Float(target.width), Float(target.height)),
                .init("halfPixel", 0.5 / Float(source.width), 0.5 / Float(source.height)),
                .init("spread", spread),
            ])
            source = target
        }
        for target in upTargets {
            gpu.pass(into: target, body: LiquidGlassShaders.kawaseUp, samplers: [.init("source", source)], uniforms: [
                .init("outputSize", Float(target.width), Float(target.height)),
                .init("halfPixel", 0.5 / Float(source.width), 0.5 / Float(source.height)),
                .init("spread", spread),
            ])
            source = target
        }
    }

    /// Composites `element` over `scene` into `target`, everywhere or only inside `rect` (target pixels), faded by `opacity`.
    public func composite(scene: Texture, into target: Texture, element: LiquidGlass, rect: Rect? = nil, opacity: Float = 1) {
        let a = element.primary
        let b = element.secondary
        let pill = element.pill
        gpu.pass(into: target, header: LiquidGlassShaders.header, body: LiquidGlassShaders.composite, samplers: [
            .init("scene", scene), .init("frost", frost), .init("tiny", tiny),
        ], uniforms: [
            .init("size", Float(target.width), Float(target.height)),
            .init("shapeA", a.centerX, a.centerY, a.halfWidth, a.halfHeight),
            .init("shapeB", b?.centerX ?? 0, b?.centerY ?? 0, b?.halfWidth ?? 0, b?.halfHeight ?? 0),
            .init("radii", a.radius, b?.radius ?? 0),
            .init("blend", element.blend),
            .init("pill", pill?.centerX ?? 0, pill?.centerY ?? 0, pill?.halfWidth ?? 0, pill?.halfHeight ?? 0),
            .init("pillRadius", pill?.radius ?? 0),
            .init("rimWidth", element.rimWidth),
            .init("refraction", element.refraction),
            .init("dispersion", element.dispersion),
            .init("light", element.lightX, element.lightY),
            .init("press", element.press),
            .init("clearness", element.variant == .clear ? 1 : 0),
            .init("shadowOpacity", element.shadowOpacity * opacity),
            .init("opacity", opacity),
            .init("shadowOffset", 0, element.shadowOffsetY),
            .init("shadowRadius", element.shadowRadius),
        ], rect: rect.map { area in
            (area.x.rounded(.down), area.y.rounded(.down), area.maxX.rounded(.up), area.maxY.rounded(.up))
        })
    }
}
