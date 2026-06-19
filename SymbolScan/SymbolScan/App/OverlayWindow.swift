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

    init(index: SymbolIndex) {
        self.index = index
        let window = OverlayWindow()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(trigger: EventTap.Trigger) {
        guard let screen = NSScreen.main else { return }

        // Position: centered horizontally, upper third of screen
        let width: CGFloat = 520
        let height: CGFloat = 420
        let x = (screen.frame.width - width) / 2
        let y = screen.frame.height * 0.62

        window?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        let pickerView = SymbolPickerView(index: index, trigger: trigger) { [weak self] in
            self?.hide()
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
    }
}
