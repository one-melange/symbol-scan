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
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No dock icon

        // Under the test host, skip the event tap / Accessibility prompt / repo indexing.
        // Unit tests exercise the logic directly and must not trigger system side effects.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        requestPermissions()

        let index = SymbolIndex()
        symbolIndex = index
        let controller = OverlayWindowController(index: index)
        overlayWindowController = controller
        controller.onChooseRepo = { [weak self] in self?.chooseRepo() }
        controller.onReindex = { [weak self] in self?.reindex() }

        statusItem = StatusItemController(
            index: index,
            onChooseRepo: { [weak self] in self?.chooseRepo() },
            onReindex: { [weak self] in self?.reindex() },
            onSwitch: { [weak self] url in self?.switchTo(url) }
        )

        eventTap = EventTap { [weak self] trigger in
            guard let self else { return }
            self.overlayWindowController?.show(trigger: trigger)
        }
        eventTap?.start()

        // Restore the last active repo. If a cache exists it loads instantly; otherwise it scans.
        if let active = RepoPreference.loadActive() {
            Task { [weak self] in
                await self?.symbolIndex?.activateRepo(active)
                // If activation left us with no index, the repo is gone/invalid — forget it so we
                // don't keep retrying a dead path every launch.
                if self?.symbolIndex?.indexedRepoRoot == nil {
                    RepoPreference.clear(active)
                }
            }
        }
    }

    // MARK: - Repo commands

    /// Present a directory picker; on selection, make it active and index it (from cache if present).
    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index Repo"
        panel.message = "Choose a git repository to index"
        panel.directoryURL = symbolIndex?.indexedRepoRoot ?? RepoPreference.loadActive()

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        RepoPreference.setActive(url)
        Task { [weak self] in await self?.symbolIndex?.activateRepo(url) }
    }

    /// Rescan the active repo from scratch (bypassing the cache).
    private func reindex() {
        guard let root = symbolIndex?.indexedRepoRoot ?? RepoPreference.loadActive() else { return }
        Task { [weak self] in await self?.symbolIndex?.reindex(root) }
    }

    /// Switch to an already-known repo (from the recents menu).
    private func switchTo(_ url: URL) {
        RepoPreference.setActive(url)
        Task { [weak self] in await self?.symbolIndex?.activateRepo(url) }
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

// MARK: - Status item

/// The menu-bar presence: the app's only durable UI (it's `.accessory`, so no dock icon and,
/// before this, no way to quit). Rebuilds its menu on open so the header/count stay live. Lives in
/// this file so it builds without a project-file edit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let index: SymbolIndex
    private let onChooseRepo: () -> Void
    private let onReindex: () -> Void
    private let onSwitch: (URL) -> Void
    private let statusItem: NSStatusItem

    init(index: SymbolIndex,
         onChooseRepo: @escaping () -> Void,
         onReindex: @escaping () -> Void,
         onSwitch: @escaping (URL) -> Void) {
        self.index = index
        self.onChooseRepo = onChooseRepo
        self.onReindex = onReindex
        self.onSwitch = onSwitch
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Claim the menu-bar slot now, but configure the button on the next runloop turn —
        // configuring it while the status bar is mid-layout triggers AppKit's
        // `_NSDetectedLayoutRecursion` warning at launch.
        DispatchQueue.main.async { [self] in
            statusItem.button?.image = NSImage(systemSymbolName: "curlybraces.square",
                                               accessibilityDescription: "SymbolScan")
            let menu = NSMenu()
            // Manual enabling: `menuNeedsUpdate` sets `isEnabled` per item (e.g. Reindex greys
            // out while indexing), which auto-enablement would silently override.
            menu.autoenablesItems = false
            menu.delegate = self
            statusItem.menu = menu
        }

        // A full menu bar (e.g. behind a MacBook notch) makes macOS hide overflow items with no
        // API to force placement. Detect it and tell the user about the keyboard fallbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let button = self?.statusItem.button,
                  let window = button.window,
                  !window.occlusionState.contains(.visible) else { return }
            print("""
            ⚠️ SymbolScan's menu-bar icon is hidden (menu bar full / notch). \
            Use the picker overlay instead: ⌘O choose repo, ⌘R reindex, ⌘Q quit.
            """)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(
            title: StatusMenuModel.title(repo: index.indexedRepoRoot,
                                         count: index.symbolCount,
                                         isIndexing: index.isIndexing,
                                         error: index.lastIndexError),
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let choose = NSMenuItem(title: "Choose Repo…", action: #selector(chooseRepo), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let reindex = NSMenuItem(title: "Reindex", action: #selector(reindexRepo), keyEquivalent: "r")
        reindex.target = self
        reindex.isEnabled = index.indexedRepoRoot != nil && !index.isIndexing
        menu.addItem(reindex)

        // Recent repos (excluding the active one) for quick switching.
        let recents = RepoPreference.loadRecents().filter { $0.path != index.indexedRepoRoot?.path }
        if !recents.isEmpty {
            menu.addItem(.separator())
            let label = NSMenuItem(title: "Recent Repos", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for url in recents {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(switchRepo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.toolTip = url.path
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SymbolScan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func chooseRepo() { onChooseRepo() }
    @objc private func reindexRepo() { onReindex() }
    @objc private func switchRepo(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onSwitch(url)
    }
}

// MARK: - Status menu copy

/// Pure derivation of the menu-bar header text from index state, split out so it's unit-testable
/// without instantiating an `NSStatusBar`.
enum StatusMenuModel {
    static func title(repo: URL?, count: Int, isIndexing: Bool, error: String?) -> String {
        guard let repo else { return "No repo selected" }
        let name = repo.lastPathComponent
        if isIndexing { return "Indexing \(name)…" }
        if let error { return "\(name): \(error)" }
        return "\(name) — \(count) symbols"
    }
}
