import Foundation

/// A view whose drawn text the pointer can select. The window keeps one selection at a time: Ctrl+C copies it when the
/// focused view takes no Ctrl+C itself, and a press anywhere else clears it.
@MainActor
public protocol TextSelecting: AnyObject {
    /// The selected text, or nil when nothing is selected.
    var selectedText: String? { get }
    func clearSelection()
}

/// A stretch of one block of text, in UTF-8 offsets: where the press began and where the pointer is now.
public struct TextSelection: Equatable, Sendable {
    public var block: String
    public var anchor: Int
    public var head: Int

    public init(block: String, anchor: Int, head: Int) {
        self.block = block
        self.anchor = anchor
        self.head = head
    }

    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    public var isEmpty: Bool { anchor == head }

    /// What `count` clicks at `index` select: one starts an empty selection there, two take the word around it, three or
    /// more the whole block.
    public static func click(_ count: Int, at index: Int, in text: String, block: String) -> TextSelection {
        switch count {
        case ...1: return TextSelection(block: block, anchor: index, head: index)
        case 2:
            let word = wordRange(in: text, around: index)
            return TextSelection(block: block, anchor: word.lowerBound, head: word.upperBound)
        default: return TextSelection(block: block, anchor: 0, head: text.utf8.count)
        }
    }

    /// The selected part of `text`, the block's text.
    public func text(in text: String) -> String {
        let bytes = Array(text.utf8)
        let lower = min(range.lowerBound, bytes.count)
        let upper = min(range.upperBound, bytes.count)
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    /// The word, or the run of spaces or punctuation, that the character boundary at `index` touches.
    static func wordRange(in text: String, around index: Int) -> Range<Int> {
        var offsets: [(start: Int, end: Int, kind: Int)] = []
        var offset = 0
        for character in text {
            let length = character.utf8.count
            offsets.append((offset, offset + length, kind(of: character)))
            offset += length
        }
        guard let hit = offsets.firstIndex(where: { index < $0.end }) ?? offsets.indices.last else { return index..<index }
        let kind = offsets[hit].kind
        var first = hit
        var last = hit
        while first > 0, offsets[first - 1].kind == kind { first -= 1 }
        while last < offsets.count - 1, offsets[last + 1].kind == kind { last += 1 }
        return offsets[first].start..<offsets[last].end
    }

    /// Letters, digits and the apostrophes inside words are one kind, spaces another, anything else a third.
    private static func kind(of character: Character) -> Int {
        if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "_" { return 0 }
        return character.isWhitespace ? 1 : 2
    }
}

/// The pointer side of a view's selectable text: the view hands over each block it draws (a key, its layout and where it
/// stands) while drawing, and presses, drags and clicks on those blocks select within them. One block holds the selection.
@MainActor
public final class TextSelector {
    public private(set) var selection: TextSelection?
    /// Redraws the view: the selection changed.
    public var onChange: (() -> Void)?

    private var blocks: [String: (layout: TextLayout, origin: Point)] = [:]
    private var isDragging = false

    public init() {}

    /// Notes a block about to be drawn at `origin` and draws its selection under it.
    public func draw(_ layout: TextLayout, key: String, at origin: Point, color: Color, in context: inout DrawContext) {
        blocks[key] = (layout, origin)
        guard let selection, selection.block == key, !selection.isEmpty else { return }
        for rect in layout.rects(forUTF8: selection.range) {
            context.fill(Rect(x: origin.x + rect.minX, y: origin.y + rect.minY, width: rect.width, height: rect.height), radius: 2, color: color)
        }
    }

    /// Forgets the blocks a redraw no longer shows; the view calls it before drawing them again.
    public func beginDrawing() {
        blocks.removeAll(keepingCapacity: true)
    }

    /// The block under `point`, if any.
    public func block(at point: Point) -> String? {
        blocks.first { contains($0.value, point) }?.key
    }

    /// A primary press at `point` (`clicks` in a row): starts a selection in the block under it. Returns false when no
    /// block is there, so the press goes on to the views behind.
    public func press(at point: Point, clicks: Int) -> Bool {
        guard let key = block(at: point), let block = blocks[key] else { return false }
        let index = block.layout.utf8Index(at: Point(x: point.x - block.origin.x, y: point.y - block.origin.y))
        selection = TextSelection.click(clicks, at: index, in: block.layout.text, block: key)
        isDragging = clicks <= 1
        onChange?()
        return true
    }

    /// The pointer moved while pressed: the selection's moving end follows it within its block.
    public func drag(to point: Point) {
        guard isDragging, var selection, let block = blocks[selection.block] else { return }
        let local = Point(x: point.x - block.origin.x, y: min(max(point.y - block.origin.y, 0), block.layout.size.height - 1))
        let index = point.y < block.origin.y ? 0
            : point.y > block.origin.y + block.layout.size.height ? block.layout.text.utf8.count
            : block.layout.utf8Index(at: local)
        guard index != selection.head else { return }
        selection.head = index
        self.selection = selection
        onChange?()
    }

    public func release() {
        isDragging = false
    }

    /// Selects the whole block `key` (a right click on text with nothing selected in it, ready for Copy).
    public func selectAll(in key: String) {
        guard let block = blocks[key] else { return }
        selection = TextSelection(block: key, anchor: 0, head: block.layout.text.utf8.count)
        onChange?()
    }

    public var selectedText: String? {
        guard let selection, !selection.isEmpty, let block = blocks[selection.block] else { return nil }
        let text = selection.text(in: block.layout.text)
        return text.isEmpty ? nil : text
    }

    public func clear() {
        guard selection != nil else { return }
        selection = nil
        isDragging = false
        onChange?()
    }

    private func contains(_ block: (layout: TextLayout, origin: Point), _ point: Point) -> Bool {
        let slack: Float = 3
        let size = block.layout.size
        return point.x >= block.origin.x - slack && point.x <= block.origin.x + size.width + slack
            && point.y >= block.origin.y - slack && point.y <= block.origin.y + size.height + slack
    }
}
