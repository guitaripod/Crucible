import Foundation

/// Kiln's drawing primitives on one target, in target pixels: rounded rectangles, artwork, text, gradients and soft
/// shadows, each a libplacebo pass limited to the pixels it touches (and to `clip`) and blended over what is there.
@MainActor
public final class Painter {
    let gpu: GPU
    public let target: Texture
    /// Pixels outside this rectangle are left alone; nil draws anywhere on the target.
    public var clip: Rect?

    public init(gpu: GPU, target: Texture) {
        self.gpu = gpu
        self.target = target
    }

    private func bounds(_ rect: Rect, outset: Float = 1) -> (Float, Float, Float, Float)? {
        var area = Rect(x: rect.x - outset, y: rect.y - outset, width: rect.width + 2 * outset, height: rect.height + 2 * outset)
        area = area.intersection(Rect(x: 0, y: 0, width: Float(target.width), height: Float(target.height)))
        if let clip { area = area.intersection(clip) }
        let x0 = area.x.rounded(.down)
        let y0 = area.y.rounded(.down)
        let x1 = area.maxX.rounded(.up)
        let y1 = area.maxY.rounded(.up)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1, y1)
    }

    /// Replaces every pixel (inside `clip`) with `color`.
    public func clear(_ color: Color) {
        let area = clip.flatMap { bounds($0, outset: 0) }
        if clip != nil && area == nil { return }
        gpu.pass(into: target, body: "color = vec4(fill.rgb, fill.a);", uniforms: [.init("fill", color.red, color.green, color.blue, color.alpha)], rect: area)
    }

    public func fill(_ rect: Rect, radius: Float = 0, color: Color) {
        guard color.alpha > 0, rect.width > 0, rect.height > 0, let area = bounds(rect) else { return }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.fill, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: area, blend: true)
    }

    /// A ring of `width` pixels inside the edge of a rounded rectangle.
    public func stroke(_ rect: Rect, radius: Float = 0, width: Float, color: Color) {
        guard color.alpha > 0, width > 0, rect.width > 0, rect.height > 0, let area = bounds(rect) else { return }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.stroke, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("lineWidth", width),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: area, blend: true)
    }

    /// A soft shadow under a rounded rectangle: `blur` is the radius of the penumbra, `offsetY` moves it down.
    public func shadow(_ rect: Rect, radius: Float, blur: Float, offsetY: Float, opacity: Float, color: Color = .black) {
        guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
        let shifted = rect.offsetBy(0, offsetY)
        guard let area = bounds(shifted, outset: blur * 2) else { return }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.shadow, uniforms: [
            .init("box", shifted.midX, shifted.midY, shifted.width / 2, shifted.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("blur", max(blur, 1)),
            .init("opacity", opacity),
            .init("tint", color.red, color.green, color.blue),
        ], rect: area, blend: true)
    }

    /// Artwork filling `rect` (cropped from the centre to its aspect, or fitted inside it), clipped to rounded corners or
    /// a circle. sRGB-encoded textures (8-bit artwork) are linearised here unless `srgb` says otherwise.
    public func image(_ texture: Texture, in rect: Rect, radius: Float = 0, opacity: Float = 1, srgb: Bool? = nil, fit: Bool = false,
                      circle: Bool = false) {
        let srgb = srgb ?? texture.isSRGB
        guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
        let imageAspect = Float(texture.width) / Float(texture.height)
        let rectAspect = rect.width / rect.height
        var crop = (x: Float(0), y: Float(0), w: Float(1), h: Float(1))
        var drawn = rect
        if fit {
            if imageAspect > rectAspect {
                drawn.height = rect.width / imageAspect
                drawn.y = rect.midY - drawn.height / 2
            } else {
                drawn.width = rect.height * imageAspect
                drawn.x = rect.midX - drawn.width / 2
            }
        } else if imageAspect > rectAspect {
            crop.w = rectAspect / imageAspect
            crop.x = (1 - crop.w) / 2
        } else {
            crop.h = imageAspect / rectAspect
            crop.y = (1 - crop.h) / 2
        }
        guard let area = bounds(drawn) else { return }
        let cornerRadius = circle ? min(drawn.width, drawn.height) / 2 : min(radius, min(drawn.width, drawn.height) / 2)
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.image, samplers: [.init("art", texture)], uniforms: [
            .init("box", drawn.midX, drawn.midY, drawn.width / 2, drawn.height / 2),
            .init("origin", drawn.x, drawn.y, drawn.width, drawn.height),
            .init("crop", crop.x, crop.y, crop.w, crop.h),
            .init("radius", cornerRadius),
            .init("opacity", opacity),
            .init("decode", srgb ? 1 : 0),
        ], rect: area, blend: true)
    }

    /// A coverage mask (text or a symbol) tinted with `color`, drawn into `rect`. A mask drawn at its own size on whole
    /// pixels is sampled exactly; a scaled one (on a lifting card) is filtered.
    public func mask(_ mask: Texture, in rect: Rect, color: Color, nearest: Bool = false) {
        guard color.alpha > 0 else { return }
        let exact = nearest || (abs(rect.width - Float(mask.width)) < 0.01 && abs(rect.height - Float(mask.height)) < 0.01)
        let placed = exact ? Rect(x: rect.x.rounded(), y: rect.y.rounded(), width: rect.width.rounded(), height: rect.height.rounded()) : rect
        guard let area = bounds(placed, outset: exact ? 0 : 1) else { return }
        gpu.pass(into: target, body: PainterShaders.mask, samplers: [.init("mask", mask, nearest: exact)], uniforms: [
            .init("origin", placed.x, placed.y, placed.width, placed.height),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: area, blend: true)
    }

    /// Coverage from a text texture, tinted, with its top left at `x`, `y`, at its own size.
    public func text(_ mask: Texture, x: Float, y: Float, color: Color) {
        self.mask(mask, in: Rect(x: x, y: y, width: Float(mask.width), height: Float(mask.height)), color: color)
    }

    /// A linear gradient across `rect`, top to bottom or left to right, through up to four stops at the given positions,
    /// clipped to rounded corners.
    public func gradient(_ rect: Rect, vertical: Bool, stops: [(position: Float, color: Color)], radius: Float = 0) {
        guard stops.count >= 2, rect.width > 0, rect.height > 0, let area = bounds(rect, outset: radius > 0 ? 1 : 0) else { return }
        let padded = Array((stops + Array(repeating: stops[stops.count - 1], count: max(0, 4 - stops.count))).prefix(4))
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.gradient, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("origin", rect.x, rect.y, rect.width, rect.height),
            .init("vertical", vertical ? 1 : 0),
            .init("positions", padded[0].position, padded[1].position, padded[2].position, padded[3].position),
            .init("c0", padded[0].color.red, padded[0].color.green, padded[0].color.blue, padded[0].color.alpha),
            .init("c1", padded[1].color.red, padded[1].color.green, padded[1].color.blue, padded[1].color.alpha),
            .init("c2", padded[2].color.red, padded[2].color.green, padded[2].color.blue, padded[2].color.alpha),
            .init("c3", padded[3].color.red, padded[3].color.green, padded[3].color.blue, padded[3].color.alpha),
        ], rect: area, blend: true)
    }

    /// A soft radial glow of `color` centred at `center`, fading out over `glowRadius`, clipped to a rounded rectangle:
    /// the specular sheen that follows the pointer across lifted artwork.
    public func glow(in rect: Rect, radius: Float, center: Point, glowRadius: Float, color: Color) {
        guard color.alpha > 0, rect.width > 0, rect.height > 0, let area = bounds(rect) else { return }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.glow, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("glowCenter", center.x, center.y),
            .init("glowRadius", max(glowRadius, 1)),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: area, blend: true)
    }

    /// Copies `source` (the same size as the target) into the target inside `rect`, or everywhere.
    public func copy(_ source: Texture, rect: Rect? = nil) {
        let area = rect.flatMap { bounds($0, outset: 0) }
        if rect != nil && area == nil { return }
        gpu.pass(into: target, body: PainterShaders.copy, samplers: [.init("source", source, nearest: true)], uniforms: [
            .init("size", Float(target.width), Float(target.height)),
        ], rect: area)
    }
}

enum PainterShaders {
    static let header = """
    float painterBox(vec2 p, vec2 halfSize, float r) {
        vec2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    vec3 painterLinear(vec3 c) {
        return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
    }
    """

    static let fill = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    color = vec4(fill.rgb, fill.a * clamp(0.5 - d, 0.0, 1.0));
    """

    static let stroke = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    float outer = clamp(0.5 - d, 0.0, 1.0);
    float inner = clamp(0.5 - (d + lineWidth), 0.0, 1.0);
    color = vec4(fill.rgb, fill.a * (outer - inner));
    """

    static let shadow = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    float a = 1.0 - smoothstep(-blur, blur, d);
    color = vec4(tint, opacity * a * a);
    """

    static let image = """
    vec2 p = gl_FragCoord.xy;
    float d = painterBox(p - box.xy, box.zw, radius);
    vec2 uv = crop.xy + (p - origin.xy) / origin.zw * crop.zw;
    vec4 texel = texture(art, uv);
    vec3 rgb = decode > 0.5 ? painterLinear(texel.rgb) : texel.rgb;
    color = vec4(rgb, texel.a * opacity * clamp(0.5 - d, 0.0, 1.0));
    """

    static let mask = """
    vec2 uv = (gl_FragCoord.xy - origin.xy) / origin.zw;
    float coverage = texture(mask, uv).r;
    color = vec4(fill.rgb, fill.a * coverage);
    """

    static let gradient = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    vec2 local = (gl_FragCoord.xy - origin.xy) / origin.zw;
    float t = vertical > 0.5 ? local.y : local.x;
    vec4 c = c0;
    c = mix(c, c1, clamp((t - positions.x) / max(positions.y - positions.x, 1e-4), 0.0, 1.0));
    c = mix(c, c2, clamp((t - positions.y) / max(positions.z - positions.y, 1e-4), 0.0, 1.0));
    c = mix(c, c3, clamp((t - positions.z) / max(positions.w - positions.z, 1e-4), 0.0, 1.0));
    color = vec4(c.rgb, c.a * clamp(0.5 - d, 0.0, 1.0));
    """

    static let glow = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    float t = length(gl_FragCoord.xy - glowCenter) / glowRadius;
    float falloff = exp(-3.0 * t * t);
    color = vec4(fill.rgb, fill.a * falloff * clamp(0.5 - d, 0.0, 1.0));
    """

    static let copy = """
    color = texture(source, gl_FragCoord.xy / size);
    """
}
