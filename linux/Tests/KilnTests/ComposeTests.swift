import CKiln
import Foundation
import Testing
@testable import Kiln

@Suite("Dead keys")
struct ComposeTests {
    /// A key as the keymap reads it, with no text yet.
    private func key(_ keysym: Int32, text: String = "") -> kiln_wl_key {
        var key = kiln_wl_key()
        key.keysym = UInt32(keysym)
        key.pressed = true
        withUnsafeMutableBytes(of: &key.text) { buffer in
            for (index, byte) in text.utf8.prefix(15).enumerated() { buffer[index] = byte }
        }
        return key
    }

    private func text(of key: kiln_wl_key) -> String {
        withUnsafeBytes(of: key.text) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    @Test func aDeadAcuteThenETypesEAcute() throws {
        let context = try #require(xkb_context_new(XKB_CONTEXT_NO_FLAGS))
        defer { xkb_context_unref(context) }
        let table = try #require(xkb_compose_table_new_from_locale(context, "en_US.UTF-8", XKB_COMPOSE_COMPILE_NO_FLAGS))
        defer { xkb_compose_table_unref(table) }
        let state = try #require(xkb_compose_state_new(table, XKB_COMPOSE_STATE_NO_FLAGS))
        defer { xkb_compose_state_unref(state) }

        var dead = key(XKB_KEY_dead_acute)
        #expect(!kiln_compose_key(state, &dead), "the dead key itself types nothing")
        var letter = key(XKB_KEY_e, text: "e")
        #expect(kiln_compose_key(state, &letter))
        #expect(text(of: letter) == "é")
        #expect(letter.keysym == UInt32(XKB_KEY_eacute))

        var plain = key(XKB_KEY_a, text: "a")
        #expect(kiln_compose_key(state, &plain))
        #expect(text(of: plain) == "a", "keys outside a sequence pass untouched")
    }
}
