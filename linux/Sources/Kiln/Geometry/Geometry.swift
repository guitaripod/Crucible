import Foundation

public struct Point: Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

public struct Size: Hashable, Sendable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: Float
    public var leading: Float
    public var bottom: Float
    public var trailing: Float

    public init(top: Float = 0, leading: Float = 0, bottom: Float = 0, trailing: Float = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all value: Float) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    public init(horizontal: Float = 0, vertical: Float = 0) {
        self.init(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }

    public static let zero = EdgeInsets()
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

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var origin: Point {
        get { Point(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    public var size: Size {
        get { Size(width: width, height: height) }
        set { width = newValue.width; height = newValue.height }
    }

    public var minX: Float { x }
    public var minY: Float { y }
    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
    public var midX: Float { x + width / 2 }
    public var midY: Float { y + height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func insetBy(_ dx: Float, _ dy: Float) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    public func inset(by insets: EdgeInsets) -> Rect {
        Rect(x: x + insets.leading, y: y + insets.top, width: width - insets.leading - insets.trailing, height: height - insets.top - insets.bottom)
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

    public func contains(_ point: Point) -> Bool { contains(point.x, point.y) }

    public func intersects(_ other: Rect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func intersection(_ other: Rect) -> Rect {
        let x0 = max(x, other.x)
        let y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func union(_ other: Rect) -> Rect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(x, other.x)
        let y0 = min(y, other.y)
        return Rect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    /// The rect with every edge on whole pixels of the given scale, so fills and images land crisply.
    public func pixelAligned(scale: Float) -> Rect {
        let x0 = (x * scale).rounded() / scale
        let y0 = (y * scale).rounded() / scale
        let x1 = (maxX * scale).rounded() / scale
        let y1 = (maxY * scale).rounded() / scale
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A uniform scale followed by a translation: every transform Kiln's views compose (layout offsets, scrolling, focus
/// lift), so rectangles stay rectangles and corner radii scale with them.
public struct Affine: Hashable, Sendable {
    public var scale: Float
    public var tx: Float
    public var ty: Float

    public init(scale: Float = 1, tx: Float = 0, ty: Float = 0) {
        self.scale = scale
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine()

    public func apply(_ point: Point) -> Point {
        Point(x: point.x * scale + tx, y: point.y * scale + ty)
    }

    public func apply(_ rect: Rect) -> Rect {
        Rect(x: rect.x * scale + tx, y: rect.y * scale + ty, width: rect.width * scale, height: rect.height * scale)
    }

    public var inverted: Affine {
        let inverse = 1 / scale
        return Affine(scale: inverse, tx: -tx * inverse, ty: -ty * inverse)
    }

    /// `self` applied after `inner`: a point goes through `inner` first.
    public func concatenating(_ inner: Affine) -> Affine {
        Affine(scale: scale * inner.scale, tx: inner.tx * scale + tx, ty: inner.ty * scale + ty)
    }
}

public enum Direction: Sendable, CaseIterable {
    case up, down, left, right

    public var isHorizontal: Bool { self == .left || self == .right }
}
