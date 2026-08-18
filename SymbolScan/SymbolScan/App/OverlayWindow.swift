import AppKit
import SwiftUI
import Combine

// MARK: - Window

class OverlayWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Core overlay properties
        self.level = .floating                // above normal windows
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false       // we need to receive keyboard/mouse
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Handles ⌘-based commands (set by the controller). Returns true if consumed. Command-key
    /// equivalents are dispatched here before the field editor sees them, so they don't collide
    /// with the navigation keys `SearchFieldRepresentable` maps in `doCommandBySelector`.
    var onCommand: ((PickerAction) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": if onCommand?(.chooseRepo) == true { return true }
            case "r": if onCommand?(.reindex) == true { return true }
            case "e": if onCommand?(.explain) == true { return true }
            case "q":
                // The menu-bar icon can be hidden (full menu bar / notch), so the overlay must
                // offer a quit path of its own.
                NSApp.terminate(nil)
                return true
            default:  break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Window Controller

class OverlayWindowController: NSWindowController {
    /// Time to let the previously-focused app regain key after `app.activate()` before we post
    /// synthetic keystrokes into it. Empirically enough for the frontmost-app handoff to settle;
    /// because we wait it out here, the subsequent `TextInjector.inject` is called with `after: 0`.
    private static let focusHandbackDelay: TimeInterval = 0.12

    private let index: SymbolIndex
    /// The local-LLM transport handed to each picker's view model (nil when the app was built/launched
    /// without a model runtime — the ⌘E explain flow then no-ops).
    private let llmClient: (any LLMClient)?
    /// Provisions the model (first-run download); handed to each view model so ⌘E can show progress.
    private let provisioner: ModelProvisioner?
    private var hostingView: NSHostingView<SymbolPickerView>?

    /// Overlay size while showing just the picker, and while an explanation pane is open. The window
    /// grows to `expandedSize` so a streamed answer isn't clipped, and shrinks back when it clears.
    private static let baseSize = NSSize(width: 520, height: 420)
    private static let expandedSize = NSSize(width: 520, height: 600)
    /// Live subscription to the current view model's explanation state, driving the resize.
    private var explanationObserver: AnyCancellable?

    /// The app that was frontmost when the overlay appeared, so we can hand focus
    /// back to it before injecting the selected symbol.
    private var previousApp: NSRunningApplication?
    /// The view model backing the currently-shown picker (nil while hidden).
    private var viewModel: SymbolPickerViewModel?
    /// The resolved trigger that opened the current picker — its action + whether the marker was
    /// already typed determine the injected prefix (see `InjectionComposer`).
    private var currentMatch: HotkeyMatch?

    /// Invoked when the user asks to choose a different repo (⌘O or the in-picker action).
    var onChooseRepo: (() -> Void)?
    /// Invoked when the user asks to rescan the active repo (⌘R or the in-picker action).
    var onReindex: (() -> Void)?
    /// Keeps workspace monitoring pinned to the originating coding app while SymbolScan is active.
    var onVisibilityChanged: ((Bool, NSRunningApplication?) -> Void)?

    init(index: SymbolIndex,
         llmClient: (any LLMClient)? = nil,
         provisioner: ModelProvisioner? = nil) {
        self.index = index
        self.llmClient = llmClient
        self.provisioner = provisioner
        let window = OverlayWindow()
        super.init(window: window)

        // The controller outlives the per-show view rebuild, so wire the window's command handler
        // once here rather than in `show(trigger:)`.
        window.onCommand = { [weak self] action in
            switch action {
            case .chooseRepo: self?.resolveAndRun { self?.onChooseRepo?() }; return true
            case .reindex:    self?.resolveAndRun { self?.onReindex?() };     return true
            case .explain:    self?.viewModel?.explain();                     return true
            default:          return false
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(match: HotkeyMatch, targetApp: NSRunningApplication? = nil) {
        guard let screen = NSScreen.main else { return }

        // AppDelegate captures this before we activate ourselves.
        // Ignore ourselves (e.g. re-trigger while the overlay is already up), preserving the prior
        // target so injection still returns to the original coding app.
        if targetApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = targetApp
        }

        // Position: centered horizontally, pinned to the top of the focused screen.
        // Must use `visibleFrame` (origin-aware, excludes menu bar/Dock) — the screen's global
        // origin is non-zero on secondary monitors, and ignoring it shoved the overlay
        // off to the side of external displays.
        let frame = OverlayPlacement.frame(in: screen.visibleFrame, size: Self.baseSize)
        window?.setFrame(frame, display: true)

        let vm = SymbolPickerViewModel(index: index, llmClient: llmClient, provisioner: provisioner)
        self.viewModel = vm
        self.currentMatch = match

        // Grow the window while an explanation pane is open (and shrink back when it clears), keeping
        // the overlay pinned to the top of the screen so a long streamed answer isn't clipped.
        explanationObserver = vm.$explanation
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { [weak self] expanded in self?.resize(expanded: expanded) }

        let pickerView = SymbolPickerView(viewModel: vm) { [weak self] action in
            switch action {
            case .inject:     self?.confirmAndHide(inject: true)
            case .copy:       self?.confirmAndHide(inject: false)
            case .dismiss:    self?.confirmAndHide(inject: false, dismissOnly: true)
            case .chooseRepo: self?.resolveAndRun { self?.onChooseRepo?() }
            case .reindex:    self?.resolveAndRun { self?.onReindex?() }
            case .explain:    self?.viewModel?.explain()
            }
        }

        let hosting = NSHostingView(rootView: pickerView)
        hosting.frame = window!.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        window?.contentView = hosting
        self.hostingView = hosting

        // Activate the app *before* ordering the window key. An `.accessory` app isn't active by
        // default, and a borderless window can't reliably become key until the app is active — do it
        // in the wrong order and the overlay appears without keyboard focus (e.g. the cursor stays
        // stuck in a terminal and the search field won't accept typing until it's clicked). The
        // search field then grabs first responder once the window is actually key (see
        // `SearchFieldRepresentable`).
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true, previousApp)
    }

    func hide() {
        let wasVisible = window?.isVisible == true
        // Cancel any in-flight explanation before dropping the view model — releasing the last
        // reference does NOT cancel its `explainTask`, so generation would otherwise keep running
        // (and burning model resources) invisibly after the overlay closes.
        explanationObserver = nil
        viewModel?.resetExplanation()
        window?.orderOut(nil)
        viewModel = nil
        if wasVisible { onVisibilityChanged?(false, previousApp) }
    }

    /// Resize the overlay between the compact picker and the taller explanation layout, re-pinning it
    /// to the top of the active screen (`OverlayPlacement` keeps the top edge fixed as height grows).
    private func resize(expanded: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let size = expanded ? Self.expandedSize : Self.baseSize
        let frame = OverlayPlacement.frame(in: screen.visibleFrame, size: size)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Dismiss the overlay, then run `action` on the next runloop turn. Dismissing first (via the
    /// dismiss-only path, which also nils `previousApp`) ensures `orderOut` completes so an
    /// NSOpenPanel opened by `action` isn't rendered behind our floating window, and that we don't
    /// re-activate the previous app before the panel appears.
    private func resolveAndRun(_ action: @escaping () -> Void) {
        confirmAndHide(inject: false, dismissOnly: true)
        DispatchQueue.main.async(execute: action)
    }

    /// Resolve the picker: inject the selected symbol, copy it, or just dismiss.
    /// Called from both the key monitor and SwiftUI tap gestures.
    private func confirmAndHide(inject: Bool, dismissOnly: Bool = false) {
        // The composed reference body (path + name for code symbols, name + parent dir for files/
        // directories) rather than the bare name — see `Symbol.injectionText` — with the
        // trigger-appropriate prefix so we don't duplicate the `@`/`#` the user already typed
        // (composition kept pure in `InjectionComposer` so it's unit-testable).
        let text = dismissOnly
            ? nil
            : viewModel?.selectedInjectionText().map {
                InjectionComposer.compose(markerAlreadyTyped: currentMatch?.passThrough ?? false, body: $0)
            }

        if inject, let text {
            hide()
            // Hand focus back to the editor, then post keystrokes once it settles.
            if let app = previousApp, !app.isTerminated {
                app.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusHandbackDelay) {
                TextInjector.inject(text, after: 0)
            }
        } else if !inject, let text {
            TextInjector.copyToClipboard(text)
            hide()
        } else {
            hide()
        }

        previousApp = nil
    }
}

// MARK: - Injection composition

/// Pure composition of the text injected/copied when a picker row is chosen, split out (like
/// `OverlayPlacement` / `StatusMenuModel`) so it's unit-testable without AppKit.
///
/// `Symbol.injectionText` supplies the reference *body*; the leading marker comes from the trigger.
/// When the bound keystroke already typed the marker into the target app (`markerAlreadyTyped` — the
/// matcher's pass-through bit, true only if the user rebound the trigger to `@`/`#`), we add nothing,
/// or it doubles (`@@…`). Otherwise — the default ⌘⇧O trigger, or any combo that types nothing — we
/// prepend `HotkeyMatcher.marker` so the reference has the same shape.
enum InjectionComposer {
    static func prefix(markerAlreadyTyped: Bool) -> String {
        markerAlreadyTyped ? "" : HotkeyMatcher.marker
    }

    static func compose(markerAlreadyTyped: Bool, body: String) -> String {
        prefix(markerAlreadyTyped: markerAlreadyTyped) + body
    }
}

// MARK: - Placement

/// Pure overlay-frame math. Lives here (rather than its own file) so it builds without a
/// project-file edit, and stays off `@MainActor`/AppKit state so it can be unit-tested —
/// including the multi-monitor regression where a screen's non-zero global origin was ignored.
enum OverlayPlacement {
    /// Horizontally centered in `visible`, pinned `topMargin` below its top edge.
    /// `visible` is expected to be the target screen's `visibleFrame` (global coordinates,
    /// menu bar/Dock excluded); AppKit rects are bottom-left-origin, so "top" is `maxY`.
    static func frame(in visible: NSRect, size: NSSize, topMargin: CGFloat = 12) -> NSRect {
        NSRect(x: visible.midX - size.width / 2,
               y: visible.maxY - topMargin - size.height,
               width: size.width,
               height: size.height)
    }
}
