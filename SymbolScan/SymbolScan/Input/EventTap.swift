import AppKit
import Carbon
import os

// MARK: - Trigger model

/// The three logical things a trigger does, independent of which key is bound to it. Replaces the
/// old hardcoded `Trigger` enum: the key combo now lives in `HotkeyBinding` (user-configurable),
/// while the *action* — and its injected marker — stays fixed.
///
/// `marker` is the character an injected reference starts with. `openSymbol` uses `"@"` because the
/// IDE-style trigger types nothing itself, so the overlay supplies the `@` (matching the old ⌘⇧O
/// behavior). For `claudeAt`/`codexHash` the marker is only *added* when the bound keystroke didn't
/// already type it — see `HotkeyMatcher` / `InjectionComposer`.
enum TriggerAction: String, Codable, CaseIterable {
    case claudeAt      // "@" reference — Claude Code
    case codexHash     // "#" reference — Codex
    case openSymbol    // IDE-style open-symbol

    var marker: String {
        switch self {
        case .claudeAt:   return "@"
        case .codexHash:  return "#"
        case .openSymbol: return "@"
        }
    }
}

/// The modifier keys of a hotkey, as a `Codable` `OptionSet` so bindings round-trip through
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

/// A single key combination: a virtual key code plus its required modifiers.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: HotkeyModifiers
}

/// The user-configurable binding for each action. Persisted as one JSON blob by `HotkeyPreference`.
struct HotkeyBindings: Codable, Equatable {
    var claudeAt: HotkeyBinding
    var codexHash: HotkeyBinding
    var openSymbol: HotkeyBinding

    /// Today's shipping combos: `@` (⇧2), `#` (⇧3), open-symbol (⌘⇧O). `@`/`#` are the *natural*
    /// typing of their markers, so at defaults they pass through and behave exactly as before.
    static let defaults = HotkeyBindings(
        claudeAt:   HotkeyBinding(keyCode: kVK_ANSI_2, modifiers: [.shift]),
        codexHash:  HotkeyBinding(keyCode: kVK_ANSI_3, modifiers: [.shift]),
        openSymbol: HotkeyBinding(keyCode: kVK_ANSI_O, modifiers: [.command, .shift])
    )

    /// Ordered `(action, binding)` pairs — the order `HotkeyMatcher` resolves ties in.
    var all: [(TriggerAction, HotkeyBinding)] {
        [(.claudeAt, claudeAt), (.codexHash, codexHash), (.openSymbol, openSymbol)]
    }

    subscript(action: TriggerAction) -> HotkeyBinding {
        get {
            switch action {
            case .claudeAt:   return claudeAt
            case .codexHash:  return codexHash
            case .openSymbol: return openSymbol
            }
        }
        set {
            switch action {
            case .claudeAt:   claudeAt = newValue
            case .codexHash:  codexHash = newValue
            case .openSymbol: openSymbol = newValue
            }
        }
    }
}

// MARK: - Matching

/// The result of resolving a keystroke: which action fired, and whether the keystroke should be
/// passed through to the target app (because it already types the marker) rather than suppressed.
struct HotkeyMatch: Equatable {
    let action: TriggerAction
    let passThrough: Bool
}

/// Pure, dependency-free hotkey resolution — the seam that makes `EventTap.handle` a thin wrapper
/// and lets the whole trigger matrix be unit-tested without a CGEventTap or Accessibility.
enum HotkeyMatcher {

    /// The marker a keystroke would *type* into the target app, or nil if it types nothing we care
    /// about. Only the two default bindings (⇧2→`@`, ⇧3→`#`) type a marker; a rebind to any other
    /// combo types nothing printable we want, so it returns nil and the trigger is suppressed.
    static func naturalMarker(keyCode: Int, modifiers: HotkeyModifiers) -> String? {
        guard modifiers == [.shift] else { return nil }
        switch keyCode {
        case kVK_ANSI_2: return "@"
        case kVK_ANSI_3: return "#"
        default:         return nil
        }
    }

    /// Resolve `(keyCode, modifiers)` against the bindings. Matching is **exact** modifier-set
    /// equality (not `contains`), so ⌘⇧2 does not fire the bare-⇧ `@` binding and ⌃2 does not fire
    /// ⇧2. `passThrough` is true iff the matched binding is the natural typing of its action's
    /// marker — i.e. the marker is already going into the buffer, so we must not suppress it (and
    /// `InjectionComposer` must not add it again).
    static func match(keyCode: Int, modifiers: HotkeyModifiers, bindings: HotkeyBindings) -> HotkeyMatch? {
        for (action, binding) in bindings.all where binding.keyCode == keyCode && binding.modifiers == modifiers {
            let passThrough = naturalMarker(keyCode: binding.keyCode, modifiers: binding.modifiers) == action.marker
            return HotkeyMatch(action: action, passThrough: passThrough)
        }
        return nil
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

/// Persists the user's trigger bindings as a single JSON blob in `UserDefaults`. Lives here (rather
/// than its own file) so it builds without a project-file edit — same rationale as `RepoPreference`
/// in `RepoScanner.swift`, which this mirrors: injectable `UserDefaults` for tests, and a pure
/// `decode` that never touches disk and falls back to `.defaults` on any missing/corrupt data.
enum HotkeyPreference {
    static let bindingsKey = "SymbolScan.hotkeyBindings"

    /// Pure: turn stored bytes into bindings, or `.defaults` if absent/empty/undecodable. The
    /// decode seam tests use directly.
    static func decode(_ data: Data?) -> HotkeyBindings {
        guard let data, !data.isEmpty,
              let bindings = try? JSONDecoder().decode(HotkeyBindings.self, from: data)
        else { return .defaults }
        return bindings
    }

    static func load(from d: UserDefaults = .standard) -> HotkeyBindings {
        decode(d.data(forKey: bindingsKey))
    }

    static func save(_ bindings: HotkeyBindings, in d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        d.set(data, forKey: bindingsKey)
    }

    static func reset(in d: UserDefaults = .standard) {
        d.removeObject(forKey: bindingsKey)
    }
}

// MARK: - Event tap

/// Global keyboard tap that fires `onTrigger` when a bound combo is pressed. The trigger *matrix*
/// is data-driven (`HotkeyMatcher` + `currentBindings`); this class is just the CGEventTap plumbing
/// plus the pass-through/suppress decision handed to it by the matcher.
class EventTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTrigger: (HotkeyMatch) -> Void

    /// Live bindings the callback matches against. Swapped by `updateBindings` when the user edits
    /// them; the change takes effect on the next keystroke with no tap teardown.
    private var currentBindings: HotkeyBindings

    /// When true, matched combos are ignored (passed through, no `onTrigger`). Set while the
    /// settings key-recorder is capturing, so pressing a still-bound combo to *record* it doesn't
    /// also pop the overlay.
    var recordingSuspended = false

    init(bindings: HotkeyBindings = HotkeyPreference.load(),
         onTrigger: @escaping (HotkeyMatch) -> Void) {
        self.currentBindings = bindings
        self.onTrigger = onTrigger
    }

    /// Swap the live bindings. Must be called on the main thread — the CGEvent callback runs on the
    /// main run loop (the tap is added to `CFRunLoopGetCurrent()` from `applicationDidFinishLaunching`,
    /// which is main), so there's no cross-thread access to `currentBindings` and no lock is needed.
    func updateBindings(_ bindings: HotkeyBindings) {
        currentBindings = bindings
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

        // While the settings recorder is active, don't fire triggers — let every key through so the
        // user can (re)bind a combo that's currently live without the overlay appearing.
        guard !recordingSuspended else { return Unmanaged.passRetained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = HotkeyModifiers(cgFlags: event.flags)

        guard let match = HotkeyMatcher.match(keyCode: keyCode, modifiers: modifiers, bindings: currentBindings) else {
            return Unmanaged.passRetained(event)
        }

        DispatchQueue.main.async { self.onTrigger(match) }
        // Pass the keystroke through only when it types the marker into the target app; otherwise
        // suppress it (the marker is injected as a prefix instead — see `InjectionComposer`).
        return match.passThrough ? Unmanaged.passRetained(event) : nil
    }

    deinit { stop() }
}
