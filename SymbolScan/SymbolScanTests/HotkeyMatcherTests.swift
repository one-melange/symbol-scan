import Testing
import Carbon
@testable import SymbolScan

/// The single-hotkey matcher. Covers exact-modifier matching and the pass-through rule that decides
/// whether the marker is typed into the target app or injected as a prefix — the one behavior that
/// can corrupt the user's editor buffer if it's wrong.
@Suite struct HotkeyMatcherTests {

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

    // MARK: - Default trigger (⌘⇧O) suppresses

    @Test func defaultBindingMatchesAndSuppresses() {
        let m = HotkeyMatcher.match(keyCode: kVK_ANSI_O, modifiers: [.command, .shift],
                                    binding: HotkeyPreference.defaultBinding)
        #expect(m == HotkeyMatch(passThrough: false))
    }

    // MARK: - A rebound pass-through trigger (@)

    @Test func atBindingPassesThrough() {
        let at = HotkeyBinding(keyCode: kVK_ANSI_2, modifiers: [.shift])
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.shift], binding: at)
                == HotkeyMatch(passThrough: true))
    }

    // MARK: - Exact-modifier discrimination

    @Test func extraOrMissingModifierDoesNotMatch() {
        let binding = HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift])
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_O, modifiers: [.command, .shift, .option], binding: binding) == nil)
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_O, modifiers: [.command], binding: binding) == nil)
    }

    @Test func differentKeyDoesNotMatch() {
        let binding = HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift])
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_P, modifiers: [.command, .shift], binding: binding) == nil)
    }

    @Test func bareShiftAtDoesNotFireForCmdShift() {
        // ⌘⇧2 must NOT match the bare-⇧ `@` binding (would with a `contains` check).
        let at = HotkeyBinding(keyCode: kVK_ANSI_2, modifiers: [.shift])
        #expect(HotkeyMatcher.match(keyCode: kVK_ANSI_2, modifiers: [.command, .shift], binding: at) == nil)
    }
}
