import Foundation

/// Kiln's drawing primitives on one target, in target pixels: rounded rectangles, rings, soft shadows, artwork, masks (text
/// and symbols) and two-stop gradients, each limited to the pixels it touches (and to `clip`) and blended over what is
/// there. Those go into a batch that draws as one libplacebo pass, in order, when something else needs the target (a
/// glow, a longer gradient, a clear or a copy, which are passes of their own) or when `flush()` is called. Anything that
/// draws into or reads the target outside the painter (glass, a capture) flushes first.
@MainActor
public final class Painter {
    let gpu: GPU
    public let target: Texture
    /// Pixels outside this rectangle are left alone; nil draws anywhere on the target.
    public var clip: Rect?

    private var vertices: ContiguousArray<Float> = []
    private var slots: [GPU.Sampler] = []

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

    /// Draws everything batched so far, in the order it was painted.
    public func flush() {
        guard !vertices.isEmpty else { return }
        defer {
            vertices.removeAll(keepingCapacity: true)
            slots.removeAll(keepingCapacity: true)
        }
        let blanks = gpu.blankTextures(Batch.slotCount - slots.count)
        guard blanks.count == Batch.slotCount - slots.count else { return }
        let samplers = slots + blanks.enumerated().map { index, blank in
            GPU.Sampler(Batch.slotNames[slots.count + index], blank, nearest: true)
        }
        vertices.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            gpu.draw(into: target, header: PainterShaders.batchHeader, body: PainterShaders.batch, samplers: samplers, attributes: Batch.attributes,
                     vertices: base, vertexCount: buffer.count / Batch.floatsPerVertex)
        }
    }

    /// Replaces every pixel (inside `clip`) with `color`.
    public func clear(_ color: Color) {
        let area = clip.flatMap { bounds($0, outset: 0) }
        if clip != nil && area == nil { return }
        flush()
        touched(area ?? (0, 0, Float(target.width), Float(target.height)))
        gpu.pass(into: target, body: "color = vec4(fill.rgb, fill.a);", uniforms: [.init("fill", color.red, color.green, color.blue, color.alpha)], rect: area)
    }

    public func fill(_ rect: Rect, radius: Float = 0, color: Color) {
        guard color.alpha > 0, rect.width > 0, rect.height > 0, let area = bounds(rect) else { return }
        add(area, kind: .fill, box: rect, radius: min(radius, min(rect.width, rect.height) / 2), fill: color)
    }

    /// A ring of `width` pixels inside the edge of a rounded rectangle.
    public func stroke(_ rect: Rect, radius: Float = 0, width: Float, color: Color) {
        guard color.alpha > 0, width > 0, rect.width > 0, rect.height > 0, let area = bounds(rect) else { return }
        add(area, kind: .stroke, box: rect, radius: min(radius, min(rect.width, rect.height) / 2), aux: width, fill: color)
    }

    /// A soft shadow under a rounded rectangle: `blur` is the radius of the penumbra, `offsetY` moves it down.
    public func shadow(_ rect: Rect, radius: Float, blur: Float, offsetY: Float, opacity: Float, color: Color = .black) {
        guard opacity > 0, rect.width > 0, rect.height > 0 else { return }
        let shifted = rect.offsetBy(0, offsetY)
        guard let area = bounds(shifted, outset: blur * 2) else { return }
        add(area, kind: .shadow, box: shifted, radius: min(radius, min(rect.width, rect.height) / 2), aux: max(blur, 1), opacity: opacity,
            fill: color)
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
        let slot = self.slot(for: texture, nearest: false)
        let uv = UVMap(u0: crop.x - drawn.x / drawn.width * crop.w, ux: crop.w / drawn.width,
                       v0: crop.y - drawn.y / drawn.height * crop.h, vy: crop.h / drawn.height)
        add(area, kind: .image, box: drawn, radius: cornerRadius, aux: srgb ? 1 : 0, opacity: opacity, uv: uv, slot: slot)
    }

    /// A coverage mask (text or a symbol) tinted with `color`, drawn into `rect`. A mask drawn at its own size on whole
    /// pixels is sampled exactly; a scaled one (on a lifting card) is filtered.
    public func mask(_ mask: Texture, in rect: Rect, color: Color, nearest: Bool = false) {
        guard color.alpha > 0 else { return }
        let exact = nearest || (abs(rect.width - Float(mask.width)) < 0.01 && abs(rect.height - Float(mask.height)) < 0.01)
        let placed = exact ? Rect(x: rect.x.rounded(), y: rect.y.rounded(), width: rect.width.rounded(), height: rect.height.rounded()) : rect
        guard placed.width > 0, placed.height > 0, let area = bounds(placed, outset: exact ? 0 : 1) else { return }
        let slot = self.slot(for: mask, nearest: exact)
        let uv = UVMap(u0: -placed.x / placed.width, ux: 1 / placed.width, v0: -placed.y / placed.height, vy: 1 / placed.height)
        add(area, kind: .mask, box: placed, fill: color, uv: uv, slot: slot)
    }

    /// Coverage from a text texture, tinted, with its top left at `x`, `y`, at its own size.
    public func text(_ mask: Texture, x: Float, y: Float, color: Color) {
        self.mask(mask, in: Rect(x: x, y: y, width: Float(mask.width), height: Float(mask.height)), color: color)
    }

    /// A linear gradient across `rect`, top to bottom or left to right, through up to four stops at the given positions,
    /// clipped to rounded corners.
    public func gradient(_ rect: Rect, vertical: Bool, stops: [(position: Float, color: Color)], radius: Float = 0) {
        gradient(rect, axis: vertical ? .vertical : .horizontal, stops: stops, radius: radius)
    }

    public func gradient(_ rect: Rect, axis: GradientAxis, stops: [(position: Float, color: Color)], radius: Float = 0) {
        guard stops.count >= 2, rect.width > 0, rect.height > 0, let area = bounds(rect, outset: radius > 0 ? 1 : 0) else { return }
        let cornerRadius = min(radius, min(rect.width, rect.height) / 2)
        guard stops.count > 2 else {
            let span = max(stops[1].position - stops[0].position, 1e-4)
            let ax = axis.vector.x / rect.width / span
            let ay = axis.vector.y / rect.height / span
            let uv = UVMap(u0: -(rect.x * ax + rect.y * ay) - stops[0].position / span, ux: ax, uy: ay, v0: 0, vy: 0)
            add(area, kind: .gradient, box: rect, radius: cornerRadius, fill: stops[0].color, fill2: stops[1].color, uv: uv)
            return
        }
        flush()
        touched(area)
        let padded = Array((stops + Array(repeating: stops[stops.count - 1], count: max(0, 4 - stops.count))).prefix(4))
        gpu.pass(into: target, header: PainterShaders.header, body: PainterShaders.gradient, uniforms: [
            .init("box", rect.midX, rect.midY, rect.width / 2, rect.height / 2),
            .init("radius", cornerRadius),
            .init("origin", rect.x, rect.y, rect.width, rect.height),
            .init("axis", axis.vector.x, axis.vector.y),
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
        flush()
        touched(area)
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
        flush()
        touched(area ?? (0, 0, Float(target.width), Float(target.height)))
        gpu.pass(into: target, body: PainterShaders.copy, samplers: [.init("source", source, nearest: true)], uniforms: [
            .init("size", Float(target.width), Float(target.height)),
        ], rect: area)
    }

    // MARK: What glass sees

    /// Target pixels drawn since glass last blurred the backdrop, leaving out what was drawn on that glass itself (its
    /// label, its icon): glass beside it does not see those, as in a tvOS glass container.
    private var drawnSinceBlur: [Rect] = []
    /// The glass composited since the backdrop was last blurred.
    private(set) var glassSinceBlur: [Rect] = []

    /// The backdrop was just blurred from the target as it is now.
    func backdropBlurred() {
        drawnSinceBlur.removeAll(keepingCapacity: true)
        glassSinceBlur.removeAll(keepingCapacity: true)
    }

    /// Glass covering `rect` was composited.
    func glassDrawn(_ rect: Rect) {
        glassSinceBlur.append(rect)
    }

    /// Whether anything glass would see inside `rect` was drawn since the last blur.
    func drawnSinceBlur(intersects rect: Rect) -> Bool {
        drawnSinceBlur.contains { $0.intersects(rect) }
    }

    private func touched(_ area: (Float, Float, Float, Float)) {
        let (x0, y0, x1, y1) = area
        if glassSinceBlur.contains(where: { $0.x <= x0 && $0.y <= y0 && $0.maxX >= x1 && $0.maxY >= y1 }) { return }
        let rect = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let last = drawnSinceBlur.last, last.x <= x0, last.y <= y0, last.maxX >= x1, last.maxY >= y1 { return }
        if drawnSinceBlur.count >= 24 {
            let merged = drawnSinceBlur.reduce(rect) { $0.union($1) }
            drawnSinceBlur.removeAll(keepingCapacity: true)
            drawnSinceBlur.append(merged)
        } else {
            drawnSinceBlur.append(rect)
        }
    }

    // MARK: Batching

    /// What one batched primitive is; the batch shader branches on it.
    private enum Kind: Float {
        case fill = 0, stroke = 1, shadow = 2, image = 3, mask = 4, gradient = 5
    }

    /// Texture coordinates (or a gradient's position in `u`) as an affine function of the target pixel.
    private struct UVMap {
        var u0: Float = 0
        var ux: Float = 0
        var uy: Float = 0
        var v0: Float = 0
        var vx: Float = 0
        var vy: Float = 0
    }

    /// The batch's vertex layout and sampler slots, shared by every painter.
    private enum Batch {
        static let slotCount = 16
        static let slotNames = (0..<slotCount).map { "tex\($0)" }
        static let attributes: [GPU.Attribute] = [
            .init("kPos", components: 2), .init("kBox", components: 4), .init("kShape", components: 4), .init("kFill", components: 4),
            .init("kFill2", components: 4), .init("kUV", components: 2), .init("kSlot", components: 1),
        ]
        static let floatsPerVertex = 21
    }

    /// The slot `texture` is bound to in the batch, adding it. A texture takes one slot per pass, so the batch is drawn
    /// first when every slot is taken or when the texture is already bound with the other filter.
    private func slot(for texture: Texture, nearest: Bool) -> Int {
        if let index = slots.firstIndex(where: { $0.texture === texture }) {
            if slots[index].nearest == nearest { return index }
            flush()
        }
        if slots.count == Batch.slotCount { flush() }
        slots.append(GPU.Sampler(Batch.slotNames[slots.count], texture, nearest: nearest))
        return slots.count - 1
    }

    /// Appends one primitive as two triangles covering `area` (whole target pixels, already clipped).
    private func add(_ area: (Float, Float, Float, Float), kind: Kind, box: Rect, radius: Float = 0, aux: Float = 0, opacity: Float = 1,
                     fill: Color = .black, fill2: Color = .black, uv: UVMap = UVMap(), slot: Int = 0) {
        touched(area)
        let (x0, y0, x1, y1) = area
        let cx = box.midX
        let cy = box.midY
        let hw = box.width / 2
        let hh = box.height / 2
        func vertex(_ x: Float, _ y: Float) {
            vertices.append(x)
            vertices.append(y)
            vertices.append(cx)
            vertices.append(cy)
            vertices.append(hw)
            vertices.append(hh)
            vertices.append(radius)
            vertices.append(aux)
            vertices.append(opacity)
            vertices.append(kind.rawValue)
            vertices.append(fill.red)
            vertices.append(fill.green)
            vertices.append(fill.blue)
            vertices.append(fill.alpha)
            vertices.append(fill2.red)
            vertices.append(fill2.green)
            vertices.append(fill2.blue)
            vertices.append(fill2.alpha)
            vertices.append(uv.u0 + uv.ux * x + uv.uy * y)
            vertices.append(uv.v0 + uv.vx * x + uv.vy * y)
            vertices.append(Float(slot))
        }
        vertex(x0, y0)
        vertex(x1, y0)
        vertex(x0, y1)
        vertex(x1, y0)
        vertex(x1, y1)
        vertex(x0, y1)
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

    /// The batch's sampler lookup: one of sixteen slots, chosen per primitive.
    static let batchHeader = header + """
    vec4 painterSample(int slot, vec2 uv) {
        if (slot == 0) return textureLod(tex0, uv, 0.0);
        if (slot == 1) return textureLod(tex1, uv, 0.0);
        if (slot == 2) return textureLod(tex2, uv, 0.0);
        if (slot == 3) return textureLod(tex3, uv, 0.0);
        if (slot == 4) return textureLod(tex4, uv, 0.0);
        if (slot == 5) return textureLod(tex5, uv, 0.0);
        if (slot == 6) return textureLod(tex6, uv, 0.0);
        if (slot == 7) return textureLod(tex7, uv, 0.0);
        if (slot == 8) return textureLod(tex8, uv, 0.0);
        if (slot == 9) return textureLod(tex9, uv, 0.0);
        if (slot == 10) return textureLod(tex10, uv, 0.0);
        if (slot == 11) return textureLod(tex11, uv, 0.0);
        if (slot == 12) return textureLod(tex12, uv, 0.0);
        if (slot == 13) return textureLod(tex13, uv, 0.0);
        if (slot == 14) return textureLod(tex14, uv, 0.0);
        return textureLod(tex15, uv, 0.0);
    }
    """

    static let batch = """
    vec2 p = gl_FragCoord.xy;
    int kind = int(kShape.w + 0.5);
    float d = painterBox(p - kBox.xy, kBox.zw, kShape.x);
    float edge = clamp(0.5 - d, 0.0, 1.0);
    if (kind == 0) {
        color = vec4(kFill.rgb, kFill.a * edge);
    } else if (kind == 1) {
        float inner = clamp(0.5 - (d + kShape.y), 0.0, 1.0);
        color = vec4(kFill.rgb, kFill.a * (edge - inner));
    } else if (kind == 2) {
        float a = 1.0 - smoothstep(-kShape.y, kShape.y, d);
        color = vec4(kFill.rgb, kShape.z * a * a);
    } else if (kind == 3) {
        vec4 texel = painterSample(int(kSlot + 0.5), kUV);
        vec3 rgb = kShape.y > 0.5 ? painterLinear(texel.rgb) : texel.rgb;
        color = vec4(rgb, texel.a * kShape.z * edge);
    } else if (kind == 4) {
        float coverage = painterSample(int(kSlot + 0.5), kUV).r;
        color = vec4(kFill.rgb, kFill.a * coverage);
    } else {
        vec4 c = mix(kFill, kFill2, clamp(kUV.x, 0.0, 1.0));
        color = vec4(c.rgb, c.a * edge);
    }
    """






    static let gradient = """
    float d = painterBox(gl_FragCoord.xy - box.xy, box.zw, radius);
    vec2 local = (gl_FragCoord.xy - origin.xy) / origin.zw;
    float t = dot(local, axis);
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
