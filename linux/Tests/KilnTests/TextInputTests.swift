import Foundation
import Testing
@testable import Kiln

@MainActor
private final class Field: View, TextInputClient {
    var applied: [TextInputEvent] = []
    override var canBecomeFocused: Bool { true }
    var textInputState: TextInputState { TextInputState(text: "", cursor: 0, anchor: 0, caret: .zero) }
    func applyTextInput(_ event: TextInputEvent) { applied.append(event) }
}

@Suite("Input method")
struct TextInputTests {
    @Test func deletionCountsBytesAroundTheCaretThenTheCommitGoesIn() {
        let event = TextInputEvent(commit: "人", deleteBefore: 3)
        let result = event.applied(to: "日本語です", caret: 3)
        #expect(result.text == "日本人です")
        #expect(result.caret == 3)
    }

    @Test func deletionAfterTheCaretAndPlainCommits() {
        #expect(TextInputEvent(deleteAfter: 2).applied(to: "abcd", caret: 1) == ("ad", 1))
        #expect(TextInputEvent(commit: "é").applied(to: "cafe", caret: 3) == ("cafée", 4))
        #expect(TextInputEvent().applied(to: "same", caret: 9) == ("same", 4), "a caret past the end stays at the end")
    }

    @Test func aDeletionThroughHalfACharacterTakesTheWholeCharacter() {
        #expect(TextInputEvent(deleteBefore: 1).applied(to: "日本", caret: 2) == ("日", 1))
        #expect(TextInputEvent.characterIndex(in: Array("日本"), atUTF8: 4, roundingUp: true) == 2)
        #expect(TextInputEvent.characterIndex(in: Array("日本"), atUTF8: 4, roundingUp: false) == 1)
    }

    @Test @MainActor func theInputMethodFollowsTheFocusedTextField() throws {
        let window = try Window(offscreen: Size(width: 400, height: 200), gpu: TestGPU.shared)
        let field = Field(frame: Rect(x: 0, y: 0, width: 200, height: 40))
        let button = Tile("button", frame: Rect(x: 0, y: 100, width: 200, height: 40))
        window.contentView.addSubview(field)
        window.contentView.addSubview(button)
        window.focus.focus(field, animated: false)
        #expect(window.textInputClient === field)
        window.focus.focus(button, animated: false)
        #expect(window.textInputClient == nil)
        window.focus.focus(field, animated: false)
        field.removeFromSuperview()
        #expect(window.textInputClient == nil, "a removed field lets go of the input method")
    }
}
