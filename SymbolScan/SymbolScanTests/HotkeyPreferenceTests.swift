import Testing
import Foundation
import Carbon
@testable import SymbolScan

/// Persistence + display formatting for the single configurable hotkey. Mirrors `RepoPreferenceTests`:
/// a throwaway `UserDefaults` suite and a pure `decode` seam that never touches disk.
@Suite struct HotkeyPreferenceTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SymbolScanTests.\(UUID().uuidString)")!
    }

    // MARK: - decode (pure)

    @Test func decodeNilOrEmptyReturnsDefault() {
        #expect(HotkeyPreference.decode(nil) == HotkeyPreference.defaultBinding)
        #expect(HotkeyPreference.decode(Data()) == HotkeyPreference.defaultBinding)
    }

    @Test func decodeCorruptReturnsDefault() {
        #expect(HotkeyPreference.decode(Data("not json".utf8)) == HotkeyPreference.defaultBinding)
    }

    @Test func defaultIsCmdShiftO() {
        #expect(HotkeyPreference.defaultBinding == HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift]))
    }

    // MARK: - UserDefaults round-trip

    @Test func saveThenLoadRoundTrips() {
        let d = makeDefaults()
        let binding = HotkeyBinding(keyCode: kVK_ANSI_K, modifiers: [.command, .shift])
        HotkeyPreference.save(binding, in: d)
        #expect(HotkeyPreference.load(from: d) == binding)
    }

    @Test func loadWithoutSaveReturnsDefault() {
        #expect(HotkeyPreference.load(from: makeDefaults()) == HotkeyPreference.defaultBinding)
    }

    @Test func resetRestoresDefault() {
        let d = makeDefaults()
        HotkeyPreference.save(HotkeyBinding(keyCode: kVK_ANSI_J, modifiers: [.control]), in: d)
        HotkeyPreference.reset(in: d)
        #expect(HotkeyPreference.load(from: d) == HotkeyPreference.defaultBinding)
    }

    // MARK: - displayString / keyLabel

    @Test func displayStringUsesCanonicalModifierOrder() {
        // Order must be ⌃⌥⇧⌘ regardless of insertion order.
        let b = HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift, .option, .control])
        #expect(b.displayString == "⌃⌥⇧⌘O")
    }

    @Test func displayStringForCommonBindings() {
        #expect(HotkeyBinding(keyCode: kVK_ANSI_2, modifiers: [.shift]).displayString == "⇧2")
        #expect(HotkeyPreference.defaultBinding.displayString == "⇧⌘O")
    }

    @Test func keyLabelCoversLettersDigitsAndFallsBack() {
        #expect(HotkeyBinding.keyLabel(for: kVK_ANSI_A) == "A")
        #expect(HotkeyBinding.keyLabel(for: kVK_ANSI_9) == "9")
        #expect(HotkeyBinding.keyLabel(for: kVK_Escape) == "Esc")
        // Unknown keycode never traps or returns empty.
        #expect(HotkeyBinding.keyLabel(for: 999) == "key999")
    }
}
