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
        func linear(_ component: UInt32) -> Float {
            let value = Float(component) / 255
            return value <= 0.04045 ? value / 12.92 : Float(pow(Double((value + 0.055) / 1.055), 2.4))
        }
        red = linear((hex >> 16) & 0xFF)
        green = linear((hex >> 8) & 0xFF)
        blue = linear(hex & 0xFF)
        self.alpha = alpha
    }

    public func withAlpha(_ alpha: Float) -> Color {
        Color(linearRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let white = Color(linearRed: 1, green: 1, blue: 1)
    public static let black = Color(linearRed: 0, green: 0, blue: 0)
    public static let clear = Color(linearRed: 0, green: 0, blue: 0, alpha: 0)
}

public struct Rect: Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
    public var midX: Float { x + width / 2 }
    public var midY: Float { y + height / 2 }

    public func insetBy(_ dx: Float, _ dy: Float) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// Scaled about its centre, the way a focused card lifts.
    public func scaled(_ factor: Float) -> Rect {
        Rect(x: midX - width * factor / 2, y: midY - height * factor / 2, width: width * factor, height: height * factor)
    }

    public func offsetBy(_ dx: Float, _ dy: Float) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func contains(_ px: Float, _ py: Float) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

/// Kiln's drawing primitives on one target: rounded rectangles, artwork, text, gradients and soft shadows, each a
/// libplacebo pass limited to the pixels it touches and blended over what is there.
@MainActor
public final class Painter {
    private let gpu: GPU
    public let target: Texture

    public init(gpu: GPU, target: Texture) {
        self.gpu = gpu
        self.target = target
    }

    private func bounds(_ rect: Rect, outset: Float = 1) -> (Float, Float, Float, Float) {
        let x0 = max(0, (rect.x - outset).rounded(.down))
        let y0 = max(0, (rect.y - outset).rounded(.down))
        let x1 = min(Float(target.width), (rect.maxX + outset).rounded(.up))
        let y1 = min(Float(target.height), (rect.maxY + outset).rounded(.up))
        return (x0, y0, max(x1, x0), max(y1, y0))
    }

    public func clear(_ color: Color) {
        gpu.pass(into: target, body: "color = vec4(fill.rgb, fill.a);", uniforms: [.init("fill", color.red, color.green, color.blue, color.alpha)])
    }

    public func fill(_ rect: Rect, radius: Float = 0, color: Color) {
        guard color.alpha > 0, rect.width > 0, rect.height > 0 else { return }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.fill, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: bounds(rect), blend: true)
    }

    /// A soft shadow under a rounded rectangle: `blur` is the radius of the penumbra, `offsetY` moves it down.
    public func shadow(_ rect: Rect, radius: Float, blur: Float, offsetY: Float, opacity: Float) {
        guard opacity > 0 else { return }
        let shifted = rect.offsetBy(0, offsetY)
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.shadow, uniforms: [
            .init("box", shifted.midX, shifted.midY, shifted.width / 2, shifted.height / 2),
            .init("radius", radius),
            .init("blur", max(blur, 1)),
            .init("opacity", opacity),
        ], rect: bounds(shifted, outset: blur * 2), blend: true)
    }

    /// Artwork filling `rect` (cropped from the centre to its aspect), clipped to rounded corners. RGBA8 images are sRGB
    /// encoded and linearised here.
    public func image(_ texture: Texture, in rect: Rect, radius: Float = 0, opacity: Float = 1, srgb: Bool = true) {
        guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
        let imageAspect = Float(texture.width) / Float(texture.height)
        let rectAspect = rect.width / rect.height
        var crop = (x: Float(0), y: Float(0), w: Float(1), h: Float(1))
        if imageAspect > rectAspect {
            crop.w = rectAspect / imageAspect
            crop.x = (1 - crop.w) / 2
        } else {
            crop.h = imageAspect / rectAspect
            crop.y = (1 - crop.h) / 2
        }
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.image, samplers: [.init("art", texture)], uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("origin", rect.x, rect.y, rect.width, rect.height),
            .init("crop", crop.x, crop.y, crop.w, crop.h),
            .init("radius", min(radius, min(rect.width, rect.height) / 2)),
            .init("opacity", opacity),
            .init("decode", srgb ? 1 : 0),
        ], rect: bounds(rect), blend: true)
    }

    /// Coverage from a text texture, tinted, with its top left at `x`, `y`.
    public func text(_ mask: Texture, x: Float, y: Float, color: Color) {
        let rect = Rect(x: x.rounded(), y: y.rounded(), width: Float(mask.width), height: Float(mask.height))
        gpu.pass(into: target, body: PainterShaders.text, samplers: [.init("mask", mask, nearest: true)], uniforms: [
            .init("origin", rect.x, rect.y, rect.width, rect.height),
            .init("fill", color.red, color.green, color.blue, color.alpha),
        ], rect: bounds(rect, outset: 0), blend: true)
    }

    /// A linear gradient across `rect`, top to bottom or left to right, through up to four stops at the given positions.
    public func gradient(_ rect: Rect, vertical: Bool, stops: [(position: Float, color: Color)]) {
        guard stops.count >= 2 else { return }
        let padded = (stops + Array(repeating: stops[stops.count - 1], count: max(0, 4 - stops.count))).prefix(4)
        let s = Array(padded)
        gpu.pass(into: target, body: PainterShaders.gradient, uniforms: [
            .init("origin", rect.x, rect.y, rect.width, rect.height),
            .init("vertical", vertical ? 1 : 0),
            .init("positions", s[0].position, s[1].position, s[2].position, s[3].position),
            .init("c0", s[0].color.red, s[0].color.green, s[0].color.blue, s[0].color.alpha),
            .init("c1", s[1].color.red, s[1].color.green, s[1].color.blue, s[1].color.alpha),
            .init("c2", s[2].color.red, s[2].color.green, s[2].color.blue, s[2].color.alpha),
            .init("c3", s[3].color.red, s[3].color.green, s[3].color.blue, s[3].color.alpha),
        ], rect: bounds(rect, outset: 0), blend: true)
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

    static let shadow = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    float a = 1.0 - smoothstep(-blur, blur, d);
    color = vec4(0.0, 0.0, 0.0, opacity * a * a);
    """

    static let image = """
    vec2 p = gl_FragCoord.xy;
    float d = painterBox(p - box.xy, box.zw, radius);
    vec2 uv = crop.xy + (p - origin.xy) / origin.zw * crop.zw;
    vec4 texel = texture(art, uv);
    vec3 rgb = decode > 0.5 ? painterLinear(texel.rgb) : texel.rgb;
    color = vec4(rgb, texel.a * opacity * clamp(0.5 - d, 0.0, 1.0));
    """

    static let text = """
    vec2 uv = (gl_FragCoord.xy - origin.xy) / origin.zw;
    float coverage = texture(mask, uv).r;
    color = vec4(fill.rgb, fill.a * coverage);
    """

    static let gradient = """
    vec2 local = (gl_FragCoord.xy - origin.xy) / origin.zw;
    float t = vertical > 0.5 ? local.y : local.x;
    vec4 c = c0;
    c = mix(c, c1, clamp((t - positions.x) / max(positions.y - positions.x, 1e-4), 0.0, 1.0));
    c = mix(c, c2, clamp((t - positions.y) / max(positions.z - positions.y, 1e-4), 0.0, 1.0));
    c = mix(c, c3, clamp((t - positions.z) / max(positions.w - positions.z, 1e-4), 0.0, 1.0));
    color = c;
    """
}
