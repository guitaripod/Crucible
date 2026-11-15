import Foundation
import Testing
@testable import Kiln

@Suite("Clipboard keys")
struct ClipboardKeyTests {
    @Test func controlLettersAndTheOlderKeysMapToCommands() {
        #expect(KeyEvent(key: .character("c"), modifiers: .control).clipboardCommand == .copy)
        #expect(KeyEvent(key: .character("X"), modifiers: [.control, .shift]).clipboardCommand == .cut)
        #expect(KeyEvent(key: .character("v"), modifiers: .control).clipboardCommand == .paste)
        #expect(KeyEvent(key: .insert, modifiers: .control).clipboardCommand == .copy)
        #expect(KeyEvent(key: .insert, modifiers: .shift).clipboardCommand == .paste)
        #expect(KeyEvent(key: .delete, modifiers: .shift).clipboardCommand == .cut)
    }

    @Test func plainLettersAndOtherChordsAreNotClipboardKeys() {
        #expect(KeyEvent(key: .character("c"), text: "c").clipboardCommand == nil)
        #expect(KeyEvent(key: .character("v"), modifiers: [.control, .alt]).clipboardCommand == nil)
        #expect(KeyEvent(key: .delete).clipboardCommand == nil)
        #expect(KeyEvent(key: .character("a"), modifiers: .control).clipboardCommand == nil)
    }
}
