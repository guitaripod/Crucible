import CKiln

/// One glass element: up to two shapes that melt into each other when close, an optional selection pill inside, and the
/// light that plays on the rim (the pointer, the focused item or the right stick).
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
    public var shadowOffsetY: Float = -10
    public var shadowRadius: Float = 26

    public init(primary: Shape, lightX: Float, lightY: Float) {
        self.primary = primary
        self.lightX = lightX
        self.lightY = lightY
    }
}

/// Blurs a frame into the frost pyramid and composites Liquid Glass over it in linear light.
@MainActor
public final class LiquidGlassRenderer {
    private let down: ShaderProgram
    private let up: ShaderProgram
    private let glass: ShaderProgram
    private let copy: ShaderProgram
    private var vertexArray: GLuint = 0
    private var downTargets: [RenderTarget] = []
    private var upTargets: [RenderTarget] = []

    public init(width: Int, height: Int) throws(RenderError) {
        down = try ShaderProgram(vertex: ShaderSources.fullscreenVertex, fragment: ShaderSources.kawaseDown)
        up = try ShaderProgram(vertex: ShaderSources.fullscreenVertex, fragment: ShaderSources.kawaseUp)
        glass = try ShaderProgram(vertex: ShaderSources.fullscreenVertex, fragment: ShaderSources.liquidGlass)
        copy = try ShaderProgram(vertex: ShaderSources.fullscreenVertex, fragment: ShaderSources.copy)
        glCreateVertexArrays(1, &vertexArray)
        try resize(width: width, height: height)
    }

    public func resize(width: Int, height: Int) throws(RenderError) {
        downTargets.forEach { $0.release() }
        upTargets.forEach { $0.release() }
        downTargets = []
        upTargets = []
        var w = width
        var h = height
        for _ in 0..<4 {
            w = max(w / 2, 1)
            h = max(h / 2, 1)
            downTargets.append(try RenderTarget(width: w, height: h))
        }
        for index in stride(from: downTargets.count - 2, through: 0, by: -1) {
            upTargets.append(try RenderTarget(width: downTargets[index].width, height: downTargets[index].height))
        }
    }

    public var frost: RenderTarget { upTargets.last ?? downTargets[0] }
    public var tiny: RenderTarget { downTargets[downTargets.count - 1] }

    public func drawFullscreen() {
        glBindVertexArray(vertexArray)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
    }

    /// Dual-Kawase blur: four halvings, then three doublings back to half resolution.
    public func blur(_ scene: RenderTarget, spread: Float = 1.6) {
        var source = scene
        down.use()
        down.set("source", sampler: 0)
        for target in downTargets {
            target.bindForDrawing()
            source.bind(unit: 0)
            down.set("halfPixel", 0.5 / Float(source.width), 0.5 / Float(source.height))
            down.set("offset", spread)
            drawFullscreen()
            source = target
        }
        up.use()
        up.set("source", sampler: 0)
        for target in upTargets {
            target.bindForDrawing()
            source.bind(unit: 0)
            up.set("halfPixel", 0.5 / Float(source.width), 0.5 / Float(source.height))
            up.set("offset", spread)
            drawFullscreen()
            source = target
        }
    }

    public func composite(scene: RenderTarget, into target: RenderTarget, element: LiquidGlass, referenceWhite: Float) {
        target.bindForDrawing()
        glass.use()
        scene.bind(unit: 0)
        frost.bind(unit: 1)
        tiny.bind(unit: 2)
        glass.set("scene", sampler: 0)
        glass.set("frost", sampler: 1)
        glass.set("tiny", sampler: 2)
        glass.set("size", Float(target.width), Float(target.height))
        let a = element.primary
        glass.set("shapeA", a.centerX, a.centerY, a.halfWidth, a.halfHeight)
        if let b = element.secondary {
            glass.set("shapeB", b.centerX, b.centerY, b.halfWidth, b.halfHeight)
            glass.set("radii", a.radius, b.radius)
        } else {
            glass.set("shapeB", 0, 0, 0, 0)
            glass.set("radii", a.radius, 0)
        }
        glass.set("blend", element.blend)
        if let pill = element.pill {
            glass.set("pill", pill.centerX, pill.centerY, pill.halfWidth, pill.halfHeight)
            glass.set("pillRadius", pill.radius)
        } else {
            glass.set("pill", 0, 0, 0, 0)
            glass.set("pillRadius", 0)
        }
        glass.set("rimWidth", element.rimWidth)
        glass.set("refraction", element.refraction)
        glass.set("dispersion", element.dispersion)
        glass.set("light", element.lightX, element.lightY)
        glass.set("press", element.press)
        glass.set("clearness", element.variant == .clear ? 1 : 0)
        glass.set("referenceWhite", referenceWhite)
        glass.set("shadowOpacity", element.shadowOpacity)
        glass.set("shadowOffset", 0, element.shadowOffsetY)
        glass.set("shadowRadius", element.shadowRadius)
        drawFullscreen()
    }

    /// Copies a target to the window's framebuffer.
    public func present(_ source: RenderTarget, width: Int, height: Int) {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        copy.use()
        source.bind(unit: 0)
        copy.set("source", sampler: 0)
        drawFullscreen()
    }
}
