import CKilnText
import Foundation

/// Which way a gradient runs across its rectangle: left to right, top to bottom, or top left to bottom right.
public enum GradientAxis: Sendable {
    case horizontal, vertical, diagonal

    var vector: (x: Float, y: Float) {
        switch self {
        case .horizontal: (1, 0)
        case .vertical: (0, 1)
        case .diagonal: (0.5, 0.5)
        }
    }
}

/// A vector drawing in points (`CGPath` with its painting folded in): lines, arcs and curves, each run of path ending in a
/// fill or a stroke with its own coverage, so a chart of many tints of one colour rasterises once and draws in one pass.
public struct Path: Hashable, Sendable {
    enum Op: Hashable, Sendable {
        case move(Point)
        case line(Point)
        case arc(center: Point, radius: Float, start: Float, end: Float, clockwise: Bool)
        case curve(Point, Point, Point)
        case close
        case fill(coverage: Float)
        case verticalRamp(fromY: Float, coverage: Float, toY: Float, toCoverage: Float)
        case stroke(width: Float, coverage: Float, round: Bool)
    }

    private(set) var ops: [Op] = []

    public init() {}

    public var isEmpty: Bool { ops.isEmpty }

    public mutating func move(to point: Point) { ops.append(.move(point)) }
    public mutating func line(to point: Point) { ops.append(.line(point)) }

    /// An arc around `center`; angles in radians from the positive x axis, growing clockwise on screen.
    public mutating func arc(center: Point, radius: Float, from start: Float, to end: Float, clockwise: Bool = true) {
        ops.append(.arc(center: center, radius: radius, start: start, end: end, clockwise: clockwise))
    }

    public mutating func curve(to end: Point, control1: Point, control2: Point) { ops.append(.curve(control1, control2, end)) }
    public mutating func close() { ops.append(.close) }

    public mutating func ellipse(in rect: Rect) {
        let radius = min(rect.width, rect.height) / 2
        ops.append(.move(Point(x: rect.midX + radius, y: rect.midY)))
        ops.append(.arc(center: Point(x: rect.midX, y: rect.midY), radius: radius, start: 0, end: 2 * .pi, clockwise: true))
        ops.append(.close)
    }

    public mutating func roundedRect(_ rect: Rect, radius: Float) {
        let r = min(radius, min(rect.width, rect.height) / 2)
        guard r > 0 else {
            ops += [.move(Point(x: rect.minX, y: rect.minY)), .line(Point(x: rect.maxX, y: rect.minY)), .line(Point(x: rect.maxX, y: rect.maxY)),
                    .line(Point(x: rect.minX, y: rect.maxY)), .close]
            return
        }
        ops.append(.move(Point(x: rect.minX + r, y: rect.minY)))
        ops.append(.arc(center: Point(x: rect.maxX - r, y: rect.minY + r), radius: r, start: -.pi / 2, end: 0, clockwise: true))
        ops.append(.arc(center: Point(x: rect.maxX - r, y: rect.maxY - r), radius: r, start: 0, end: .pi / 2, clockwise: true))
        ops.append(.arc(center: Point(x: rect.minX + r, y: rect.maxY - r), radius: r, start: .pi / 2, end: .pi, clockwise: true))
        ops.append(.arc(center: Point(x: rect.minX + r, y: rect.minY + r), radius: r, start: .pi, end: 3 * .pi / 2, clockwise: true))
        ops.append(.close)
    }

    /// Paints the path built since the last fill or stroke at `coverage` (the share of the drawing colour it gets).
    public mutating func fill(coverage: Float = 1) { ops.append(.fill(coverage: coverage)) }

    /// Paints the path with coverage running from `coverage` at `fromY` to `toCoverage` at `toY`: a wash under a line.
    public mutating func fillRamp(fromY: Float, coverage: Float, toY: Float, toCoverage: Float) {
        ops.append(.verticalRamp(fromY: fromY, coverage: coverage, toY: toY, toCoverage: toCoverage))
    }

    public mutating func stroke(width: Float, coverage: Float = 1, round: Bool = true) {
        ops.append(.stroke(width: width, coverage: coverage, round: round))
    }

    var raw: [kiln_shape_op] {
        ops.map { op in
            func make(_ verb: kiln_shape_verb, _ values: Float...) -> kiln_shape_op {
                let padded = values.map(Double.init) + Array(repeating: 0, count: 6 - values.count)
                return kiln_shape_op(verb: Int32(verb.rawValue), a: padded[0], b: padded[1], c: padded[2], d: padded[3], e: padded[4], f: padded[5])
            }
            switch op {
            case .move(let point): return make(KILN_SHAPE_MOVE, point.x, point.y)
            case .line(let point): return make(KILN_SHAPE_LINE, point.x, point.y)
            case .arc(let center, let radius, let start, let end, let clockwise):
                return make(clockwise ? KILN_SHAPE_ARC : KILN_SHAPE_ARC_NEGATIVE, center.x, center.y, radius, start, end)
            case .curve(let first, let second, let end): return make(KILN_SHAPE_CURVE, first.x, first.y, second.x, second.y, end.x, end.y)
            case .close: return make(KILN_SHAPE_CLOSE)
            case .fill(let coverage): return make(KILN_SHAPE_FILL, coverage)
            case .verticalRamp(let fromY, let coverage, let toY, let toCoverage):
                return make(KILN_SHAPE_FILL_VERTICAL_RAMP, coverage, fromY, toCoverage, toY)
            case .stroke(let width, let coverage, let round): return make(KILN_SHAPE_STROKE, width, coverage, round ? 1 : 0)
            }
        }
    }
}

/// Rasterises paths into coverage textures with Cairo and keeps the recent ones: a chart redraws from its texture until its
/// path or size changes. Shapes not drawn for two seconds of frames are dropped, so an animation's in-between frames go too.
@MainActor
final class ShapeRenderer {
    private struct Key: Hashable {
        let path: Path
        let width: Int
        let height: Int
        let scale: Float
    }

    private let gpu: GPU
    private var cache: [Key: (texture: Texture, frame: Int)] = [:]
    private var frame = 0

    init(gpu: GPU) {
        self.gpu = gpu
    }

    /// The coverage texture of `path` drawn into a box of `size` points at `scale` pixels per point.
    func texture(for path: Path, size: Size, scale: Float) -> Texture? {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, !path.isEmpty else { return nil }
        let key = Key(path: path, width: width, height: height, scale: scale)
        if let cached = cache[key] {
            cache[key]?.frame = frame
            return cached.texture
        }
        let stride = (width + 3) & ~3
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let raw = path.raw
        let rendered = raw.withUnsafeBufferPointer { ops in
            kiln_shape_render(ops.baseAddress, Int32(ops.count), Double(scale), &pixels, Int32(width), Int32(height), Int32(stride))
        }
        guard rendered, let texture = try? gpu.texture(width: width, height: height, format: .r8, renderable: false) else { return nil }
        _ = pixels.withUnsafeBytes { texture.upload($0.baseAddress!, rowBytes: stride) }
        cache[key] = (texture, frame)
        return texture
    }

    /// Ages the cache; called once per frame.
    func endFrame() {
        frame += 1
        guard frame % 120 == 0 else { return }
        cache = cache.filter { frame - $0.value.frame < 120 }
    }
}
