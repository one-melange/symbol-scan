import AppKit
import SwiftUI

@main
struct OverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No default window — we manage windows manually
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayWindowController: OverlayWindowController?
    var eventTap: EventTap?
    var symbolIndex: SymbolIndex?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No dock icon

        // Under the test host, skip the event tap / Accessibility prompt / repo indexing.
        // Unit tests exercise the logic directly and must not trigger system side effects.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        requestPermissions()

        symbolIndex = SymbolIndex()
        overlayWindowController = OverlayWindowController(index: symbolIndex!)

        eventTap = EventTap { [weak self] trigger in
            guard let self else { return }
            self.overlayWindowController?.show(trigger: trigger)
        }
        eventTap?.start()
        
        // Temporary: index this repo on launch to test
        Task {
            await symbolIndex?.index(repoRoot: URL(fileURLWithPath: "/Users/pm/Code/symbol-scan"))
        }
    }

    private func requestPermissions() {
        // Accessibility — required for CGEventTap
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("⚠️ Accessibility permission not granted. CGEventTap will not work.")
        }

        // Screen recording — required for ScreenCaptureKit
        // Triggered automatically on first SCStream use; prompt appears then.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
