import AppKit
import Carbon

struct TextInjector {

    /// Default settle delay before injecting: gives the overlay time to resign key (so the
    /// synthetic keystrokes land in the target app, not our own field). Callers that have already
    /// handed focus back — e.g. `OverlayWindow.confirmAndHide` after its own focus-handback wait —
    /// pass `after: 0` to skip a second delay.
    static let defaultInjectDelay: TimeInterval = 0.05

    /// Injects text into whatever window currently has focus.
    /// Small delay ensures the overlay has resigned key before injection.
    static func inject(_ text: String, after delay: TimeInterval = defaultInjectDelay) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            _inject(text)
        }
    }

    private static func _inject(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for scalar in text.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            var uni = UniChar(scalar.value & 0xFFFF)
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Copy text to clipboard as a fallback (Tab key action)
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
