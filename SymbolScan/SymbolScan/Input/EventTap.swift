import AppKit
import Carbon
import os

// MARK: - Trigger model

/// The modifier keys of a hotkey, as a `Codable` `OptionSet` so the binding round-trips through
/// `UserDefaults`. Rendered in canonical macOS order (`⌃⌥⇧⌘`) by `HotkeyBinding.displayString`.
struct HotkeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let shift   = HotkeyModifiers(rawValue: 1 << 1)
    static let control = HotkeyModifiers(rawValue: 1 << 2)
    static let option  = HotkeyModifiers(rawValue: 1 << 3)

    /// From the live CGEvent flags seen by the tap. Only the four we bind on are considered.
    init(cgFlags: CGEventFlags) {
        var m: HotkeyModifiers = []
        if cgFlags.contains(.maskCommand)   { m.insert(.command) }
        if cgFlags.contains(.maskShift)     { m.insert(.shift) }
        if cgFlags.contains(.maskControl)   { m.insert(.control) }
        if cgFlags.contains(.maskAlternate) { m.insert(.option) }
        self = m
    }

    /// From an `NSEvent` (used by the key-recorder UI).
    init(nsFlags: NSEvent.ModifierFlags) {
        var m: HotkeyModifiers = []
        if nsFlags.contains(.command) { m.insert(.command) }
        if nsFlags.contains(.shift)   { m.insert(.shift) }
        if nsFlags.contains(.control) { m.insert(.control) }
        if nsFlags.contains(.option)  { m.insert(.option) }
        self = m
    }

    init(rawValue: Int) { self.rawValue = rawValue }
}

/// A single key combination: a virtual key code plus its required modifiers. This *is* the trigger —
/// there is one configurable hotkey, not a per-tool set.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: HotkeyModifiers
}

// MARK: - Matching

/// The result of resolving a keystroke against the trigger: whether the keystroke should be passed
/// through to the target app (because it already types the marker) rather than suppressed.
struct HotkeyMatch: Equatable {
    let passThrough: Bool
}

/// Pure, dependency-free hotkey resolution — the seam that makes `EventTap.handle` a thin wrapper
/// and lets the trigger logic be unit-tested without a CGEventTap or Accessibility.
enum HotkeyMatcher {
    /// The character an injected reference starts with. The default trigger (⌘⇧O) types nothing, so
    /// the overlay supplies this marker; if the user rebinds to a combo that *does* type it (⇧2 → `@`),
    /// it's passed through instead and not injected again.
    static let marker = "@"

    /// The marker a keystroke would *type* into the target app, or nil if it types nothing we care
    /// about. Only ⇧2 (`@`) / ⇧3 (`#`) type one; a modifier combo like ⌘⇧O types nothing, so it
    /// returns nil and the trigger is suppressed.
    static func naturalMarker(keyCode: Int, modifiers: HotkeyModifiers) -> String? {
        guard modifiers == [.shift] else { return nil }
        switch keyCode {
        case kVK_ANSI_2: return "@"
        case kVK_ANSI_3: return "#"
        default:         return nil
        }
    }

    /// Resolve `(keyCode, modifiers)` against the trigger `binding`. Matching is **exact** modifier-set
    /// equality (not `contains`), so ⌘⇧O only fires on exactly ⌘⇧O. `passThrough` is true iff the
    /// binding is the natural typing of the marker — i.e. the marker is already going into the buffer,
    /// so we must not suppress it (and `InjectionComposer` must not add it again).
    static func match(keyCode: Int, modifiers: HotkeyModifiers, binding: HotkeyBinding) -> HotkeyMatch? {
        guard binding.keyCode == keyCode, binding.modifiers == modifiers else { return nil }
        return HotkeyMatch(passThrough: naturalMarker(keyCode: keyCode, modifiers: modifiers) == marker)
    }
}

// MARK: - Display formatting

extension HotkeyBinding {
    /// Human-readable combo, e.g. `⇧⌘O`, `⇧2`. Modifiers in canonical macOS order `⌃⌥⇧⌘`.
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + HotkeyBinding.keyLabel(for: keyCode)
    }

    /// A printable label for a virtual key code. Covers letters, digits, and common keys; unknown
    /// codes fall back to `key<n>` so this never traps or returns empty.
    static func keyLabel(for keyCode: Int) -> String {
        keyLabels[keyCode] ?? "key\(keyCode)"
    }

    private static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
        kVK_Delete: "Delete",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}

// MARK: - Persistence

/// Persists the user's trigger hotkey as a JSON blob in `UserDefaults`. Lives here (rather than its
/// own file) so it builds without a project-file edit — same rationale as `RepoPreference` in
/// `RepoScanner.swift`, which this mirrors: injectable `UserDefaults` for tests, and a pure `decode`
/// that never touches disk and falls back to `.defaultBinding` on any missing/corrupt data.
enum HotkeyPreference {
    static let key = "SymbolScan.triggerHotkey"

    /// The out-of-the-box trigger: ⌘⇧O. A modifier combo (not a printable char), so it's suppressed
    /// rather than passed through — it never reaches the app underneath, which keeps focus handoff
    /// clean (e.g. no cursor left stuck in a terminal).
    static let defaultBinding = HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift])

    /// Pure: turn stored bytes into a binding, or `.defaultBinding` if absent/empty/undecodable.
    static func decode(_ data: Data?) -> HotkeyBinding {
        guard let data, !data.isEmpty,
              let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
        else { return defaultBinding }
        return binding
    }

    static func load(from d: UserDefaults = .standard) -> HotkeyBinding {
        decode(d.data(forKey: key))
    }

    static func save(_ binding: HotkeyBinding, in d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        d.set(data, forKey: key)
    }

    static func reset(in d: UserDefaults = .standard) {
        d.removeObject(forKey: key)
    }
}

// MARK: - Event tap

/// Global keyboard tap that fires `onTrigger` when the bound combo is pressed. The trigger is
/// data-driven (`HotkeyMatcher` + `currentBinding`); this class is just the CGEventTap plumbing plus
/// the pass-through/suppress decision handed to it by the matcher.
class EventTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTrigger: (HotkeyMatch) -> Void

    /// Live trigger the callback matches against. Swapped by `updateBinding` when the user edits it;
    /// the change takes effect on the next keystroke with no tap teardown.
    private var currentBinding: HotkeyBinding

    /// When true, a matched combo is ignored (passed through, no `onTrigger`). Set while the settings
    /// key-recorder is capturing, so pressing a still-bound combo to *record* it doesn't also pop the
    /// overlay.
    var recordingSuspended = false

    init(binding: HotkeyBinding = HotkeyPreference.load(),
         onTrigger: @escaping (HotkeyMatch) -> Void) {
        self.currentBinding = binding
        self.onTrigger = onTrigger
    }

    /// Swap the live trigger. Must be called on the main thread — the CGEvent callback runs on the
    /// main run loop (the tap is added to `CFRunLoopGetCurrent()` from `applicationDidFinishLaunching`,
    /// which is main), so there's no cross-thread access to `currentBinding` and no lock is needed.
    func updateBinding(_ binding: HotkeyBinding) {
        currentBinding = binding
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // We need to bridge self into the C callback
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return eventTap.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.input.error("Failed to create CGEventTap. Check Accessibility permissions.")
            return
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // While the settings recorder is active, don't fire the trigger — let every key through so
        // the user can (re)bind a combo that's currently live without the overlay appearing.
        guard !recordingSuspended else { return Unmanaged.passRetained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = HotkeyModifiers(cgFlags: event.flags)

        guard let match = HotkeyMatcher.match(keyCode: keyCode, modifiers: modifiers, binding: currentBinding) else {
            return Unmanaged.passRetained(event)
        }

        DispatchQueue.main.async { self.onTrigger(match) }
        // Pass the keystroke through only when it types the marker into the target app; otherwise
        // suppress it (the marker is injected as a prefix instead — see `InjectionComposer`).
        return match.passThrough ? Unmanaged.passRetained(event) : nil
    }

    deinit { stop() }
}
