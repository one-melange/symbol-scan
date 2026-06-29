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

    init(index: SymbolIndex) {
        self.index = index
        let window = OverlayWindow()
        super.init(window: window)
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

        // Position: centered horizontally, upper third of screen
        let width: CGFloat = 520
        let height: CGFloat = 420
        let x = (screen.frame.width - width) / 2
        let y = screen.frame.height * 0.62

        window?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        let vm = SymbolPickerViewModel(index: index)
        self.viewModel = vm

        let pickerView = SymbolPickerView(viewModel: vm, trigger: trigger) { [weak self] action in
            switch action {
            case .inject:  self?.confirmAndHide(inject: true)
            case .copy:    self?.confirmAndHide(inject: false)
            case .dismiss: self?.confirmAndHide(inject: false, dismissOnly: true)
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

    /// Resolve the picker: inject the selected symbol, copy it, or just dismiss.
    /// Called from both the key monitor and SwiftUI tap gestures.
    private func confirmAndHide(inject: Bool, dismissOnly: Bool = false) {
        let name = dismissOnly ? nil : viewModel?.selectedSymbolName()

        if inject, let name {
            hide()
            // Hand focus back to the editor, then post keystrokes once it settles.
            if let app = previousApp, !app.isTerminated {
                app.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                TextInjector.inject(name, after: 0)
            }
        } else if !inject, let name {
            TextInjector.copyToClipboard(name)
            hide()
        } else {
            hide()
        }

        previousApp = nil
    }
}
