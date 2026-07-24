import AppKit
import SwiftUI

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
        self.sharingType = .none              // invisible to screen capture
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
    private let index: SymbolIndex
    private var hostingView: NSHostingView<SymbolPickerView>?

    /// The app that was frontmost when the overlay appeared, so we can hand focus
    /// back to it before injecting the selected symbol.
    private var previousApp: NSRunningApplication?
    /// The view model backing the currently-shown picker (nil while hidden).
    private var viewModel: SymbolPickerViewModel?

    /// Invoked when the user asks to choose a different repo (⌘O or the in-picker action).
    var onChooseRepo: (() -> Void)?
    /// Invoked when the user asks to rescan the active repo (⌘R or the in-picker action).
    var onReindex: (() -> Void)?

    init(index: SymbolIndex) {
        self.index = index
        let window = OverlayWindow()
        super.init(window: window)

        // The controller outlives the per-show view rebuild, so wire the window's command handler
        // once here rather than in `show(trigger:)`.
        window.onCommand = { [weak self] action in
            switch action {
            case .chooseRepo: self?.resolveAndRun { self?.onChooseRepo?() }; return true
            case .reindex:    self?.resolveAndRun { self?.onReindex?() };     return true
            default:          return false
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(trigger: EventTap.Trigger) {
        guard let screen = NSScreen.main else { return }

        // Capture the app that had focus when the trigger fired — must happen before
        // we activate ourselves. Ignore ourselves (e.g. re-trigger while overlay is up).
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        // Position: centered horizontally, pinned to the top of the focused screen.
        // Must use `visibleFrame` (origin-aware, excludes menu bar/Dock) — the screen's global
        // origin is non-zero on secondary monitors, and ignoring it shoved the overlay
        // off to the side of external displays.
        let frame = OverlayPlacement.frame(in: screen.visibleFrame,
                                           size: NSSize(width: 520, height: 420))
        window?.setFrame(frame, display: true)

        let vm = SymbolPickerViewModel(index: index)
        self.viewModel = vm

        let pickerView = SymbolPickerView(viewModel: vm, trigger: trigger) { [weak self] action in
            switch action {
            case .inject:     self?.confirmAndHide(inject: true)
            case .copy:       self?.confirmAndHide(inject: false)
            case .dismiss:    self?.confirmAndHide(inject: false, dismissOnly: true)
            case .chooseRepo: self?.resolveAndRun { self?.onChooseRepo?() }
            case .reindex:    self?.resolveAndRun { self?.onReindex?() }
            }
        }

        let hosting = NSHostingView(rootView: pickerView)
        hosting.frame = window!.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        window?.contentView = hosting
        self.hostingView = hosting

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        viewModel = nil
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
        // The composed reference (path + name for code symbols, name + parent dir for files/
        // directories) rather than the bare name — see `Symbol.injectionText`.
        let text = dismissOnly ? nil : viewModel?.selectedInjectionText()

        if inject, let text {
            hide()
            // Hand focus back to the editor, then post keystrokes once it settles.
            if let app = previousApp, !app.isTerminated {
                app.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
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
