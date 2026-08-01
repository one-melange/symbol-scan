import Testing
import Carbon
@testable import SymbolScan

/// The data-driven trigger matrix (T6). Covers exact-modifier matching and the pass-through rule
/// that decides whether the marker is typed into the target app or injected as a prefix — the one
/// behavior that can corrupt the user's editor buffer if it's wrong.
@Suite struct HotkeyMatcherTests {

    private let defaults = HotkeyBindings.defaults

    // MARK: - naturalMarker

    @Test func naturalMarkerOnlyForShiftDigits() {
        #expect(HotkeyMatcher.naturalMarker(keyCode: kVK_ANSI_2, modifiers: [.shift]) == "@")
        #expect(HotkeyMatcher.naturalMarker(keyCode: kVK_ANSI_3, modifiers: [.shift]) == "#")
        // Needs exactly shift — cmd+shift+2 types no marker we want.
        #expect(HotkeyMatcher.naturalMarker(keyCode: kVK_ANSI_2, modifiers: [.command, .shift]) == nil)
        // A non-digit, and a digit without shift.
        #expect(HotkeyMatcher.naturalMarker(keyCode: kVK_ANSI_O, modifiers: [.shift]) == nil)
        #expect(HotkeyMatcher.naturalMarker(keyCode: kVK_ANSI_2, modifiers: []) == nil)
    }

    // MARK: - Defaults behave exactly as before

    @Test func defaultAtPassesThrough() {
        let m = HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.shift], bindings: defaults)
        #expect(m == HotkeyMatch(action: .claudeAt, passThrough: true))
    }

    @Test func defaultHashPassesThrough() {
        let m = HotkeyMatcher.match(keyCode: kVK_ANSI_3, modifiers: [.shift], bindings: defaults)
        #expect(m == HotkeyMatch(action: .codexHash, passThrough: true))
    }

    @Test func defaultOpenSymbolSuppresses() {
        let m = HotkeyMatcher.match(keyCode: kVK_ANSI_O, modifiers: [.command, .shift], bindings: defaults)
        #expect(m == HotkeyMatch(action: .openSymbol, passThrough: false))
    }

    // MARK: - Exact-modifier discrimination

    @Test func cmdShiftDigitDoesNotFireBareShiftBinding() {
        // ⌘⇧2 must NOT match the bare-⇧ `@` binding (would with a `contains` check).
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.command, .shift], bindings: defaults) == nil)
    }

    @Test func ctrlDigitDoesNotFireShiftBinding() {
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.control], bindings: defaults) == nil)
    }

    @Test func unboundComboReturnsNil() {
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_A, modifiers: [.command], bindings: defaults) == nil)
    }

    // MARK: - Rebinds

    @Test func rebindToNonTypingComboSuppresses() {
        // Rebind Claude `@` to ⌘⇧A — types no marker, so it must suppress (and the marker gets
        // injected as a prefix downstream instead).
        var bindings = defaults
        bindings.claudeAt = HotkeyBinding(keyCode: kVK_ANSI_A, modifiers: [.command, .shift])

        let m = HotkeyMatcher.match(keyCode: kVK_ANSI_A, modifiers: [.command, .shift], bindings: bindings)
        #expect(m == HotkeyMatch(action: .claudeAt, passThrough: false))
        // The old default combo no longer fires that action.
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.shift], bindings: bindings) == nil)
    }
}
