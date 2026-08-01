import Testing
import Foundation
import Carbon
@testable import SymbolScan

/// Persistence + display formatting for the configurable hotkeys (T6). Mirrors `RepoPreferenceTests`:
/// a throwaway `UserDefaults` suite and a pure `decode` seam that never touches disk.
@Suite struct HotkeyPreferenceTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SymbolScanTests.\(UUID().uuidString)")!
    }

    // MARK: - decode (pure)

    @Test func decodeNilOrEmptyReturnsDefaults() {
        #expect(HotkeyPreference.decode(nil) == .defaults)
        #expect(HotkeyPreference.decode(Data()) == .defaults)
    }

    @Test func decodeCorruptReturnsDefaults() {
        #expect(HotkeyPreference.decode(Data("not json".utf8)) == .defaults)
    }

    // MARK: - UserDefaults round-trip

    @Test func saveThenLoadRoundTrips() {
        let d = makeDefaults()
        var bindings = HotkeyBindings.defaults
        bindings.openSymbol = HotkeyBinding(keyCode: kVK_ANSI_K, modifiers: [.command, .shift])
        HotkeyPreference.save(bindings, in: d)

        #expect(HotkeyPreference.load(from: d) == bindings)
        #expect(HotkeyPreference.load(from: d).openSymbol.keyCode == kVK_ANSI_K)
    }

    @Test func loadWithoutSaveReturnsDefaults() {
        #expect(HotkeyPreference.load(from: makeDefaults()) == .defaults)
    }

    @Test func resetRestoresDefaults() {
        let d = makeDefaults()
        var bindings = HotkeyBindings.defaults
        bindings.claudeAt = HotkeyBinding(keyCode: kVK_ANSI_J, modifiers: [.control])
        HotkeyPreference.save(bindings, in: d)
        HotkeyPreference.reset(in: d)
        #expect(HotkeyPreference.load(from: d) == .defaults)
    }

    // MARK: - displayString / keyLabel

    @Test func displayStringUsesCanonicalModifierOrder() {
        // Order must be ⌃⌥⇧⌘ regardless of insertion order.
        let b = HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift, .option, .control])
        #expect(b.displayString == "⌃⌥⇧⌘O")
    }

    @Test func displayStringForDefaults() {
        #expect(HotkeyBinding(keyCode: kVK_ANSI_2, modifiers: [.shift]).displayString == "⇧2")
        #expect(HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift]).displayString == "⇧⌘O")
    }

    @Test func keyLabelCoversLettersDigitsAndFallsBack() {
        #expect(HotkeyBinding.keyLabel(for: kVK_ANSI_A) == "A")
        #expect(HotkeyBinding.keyLabel(for: kVK_ANSI_9) == "9")
        #expect(HotkeyBinding.keyLabel(for: kVK_Escape) == "Esc")
        // Unknown keycode never traps or returns empty.
        #expect(HotkeyBinding.keyLabel(for: 999) == "key999")
    }
}
