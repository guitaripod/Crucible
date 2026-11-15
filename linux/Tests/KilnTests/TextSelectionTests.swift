import Foundation
import Testing
@testable import Kiln

@Suite("Text selection")
struct TextSelectionTests {
    @Test func doubleClickTakesTheWordUnderThePointer() {
        let text = "A retired salvage pilot’s job"
        let word = TextSelection.click(2, at: 12, in: text, block: "synopsis")
        #expect(word.text(in: text) == "salvage")
        let apostrophe = TextSelection.click(2, at: 20, in: text, block: "synopsis")
        #expect(apostrophe.text(in: text) == "pilot’s")
    }

    @Test func doubleClickBetweenWordsTakesTheSpaces() {
        let text = "Low  Tide"
        #expect(TextSelection.click(2, at: 4, in: text, block: "title").text(in: text) == "  ")
    }

    @Test func tripleClickTakesTheWholeBlock() {
        let text = "Maren Vale · Pilot"
        let all = TextSelection.click(3, at: 2, in: text, block: "fact.0")
        #expect(all.text(in: text) == text)
        #expect(TextSelection.click(1, at: 2, in: text, block: "fact.0").isEmpty)
    }

    @Test func aDragBackwardsSelectsTheSameText() {
        let text = "Halcyon"
        let backwards = TextSelection(block: "title", anchor: 5, head: 1)
        #expect(backwards.range == 1..<5)
        #expect(backwards.text(in: text) == "alcy")
    }

    @Test func multibyteTextKeepsWholeCharacters() {
        let text = "Ōkami 東京"
        let word = TextSelection.click(2, at: text.utf8.count - 1, in: text, block: "title")
        #expect(word.text(in: text) == "東京")
    }

    @Test @MainActor func selectionRectanglesCoverEveryLineTheRangeTouches() {
        let layout = TextLayout("When a derelict research platform surfaces in the Halcyon shipping lane", font: Font(size: 20), maxWidth: 220,
                                maxLines: 0, scale: 1)
        let rects = layout.rects(forUTF8: 0..<layout.text.utf8.count)
        #expect(rects.count == layout.lineCount)
        #expect(rects.allSatisfy { $0.width > 0 && $0.minX >= 0 && $0.maxX <= 221 })
        #expect(layout.rects(forUTF8: 3..<3).isEmpty)
    }

    @Test @MainActor func centredLinesHighlightWhereTheTextIs() {
        let layout = TextLayout("Night", font: Font(size: 20), maxWidth: 400, maxLines: 1, alignment: .center, scale: 1)
        let rect = layout.rects(forUTF8: 0..<5).first
        #expect(rect.map { abs($0.midX - 200) < 2 } == true)
    }
}
