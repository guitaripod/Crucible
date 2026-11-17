import Foundation
import Kiln

/// Items placed left to right and wrapped onto a new line where the next one would pass the right edge, so a row of
/// controls or tiles shows everything at once and a mouse never has to scroll it sideways.
public struct FlowLayout: Sendable {
    public var leading: Float
    public var width: Float
    public var spacing: Float
    public var lineSpacing: Float

    /// `width` is the room between the margins, starting `leading` from the left edge.
    public init(leading: Float, width: Float, spacing: Float, lineSpacing: Float) {
        self.leading = leading
        self.width = width
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    /// Where each size goes, with the lines' total height; an item wider than the room takes a line to itself.
    public func place(_ sizes: [Size]) -> (origins: [Point], height: Float) {
        var origins: [Point] = []
        var x = leading
        var y: Float = 0
        var lineHeight: Float = 0
        for size in sizes {
            if x > leading, x + size.width > leading + width + 0.5 {
                x = leading
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(Point(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, y + lineHeight)
    }
}
