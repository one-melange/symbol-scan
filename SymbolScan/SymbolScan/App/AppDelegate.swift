import AppKit
import SwiftUI
import Combine
import ServiceManagement
import os

// MARK: - Logging

/// Central `os.Logger` namespace. Lives here (rather than its own file) so it builds without a
/// project-file edit — same rationale as `StatusItemController` below and `SymbolMatcher`/
/// `RepoPreference` elsewhere. In one module these categories are visible to every subsystem.
///
/// Replaced the app's `print()` debug logging (T10). Two rules for call sites: never log raw
/// keystrokes (the old per-event keycode `print` was a privacy leak and was deleted, not migrated),
/// and interpolate user content — the search query, a repo path — with `privacy: .private` so it's
/// redacted in captured logs.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "SymbolScan"
    static let app     = Logger(subsystem: subsystem, category: "app")
    static let input   = Logger(subsystem: subsystem, category: "input")
    static let index   = Logger(subsystem: subsystem, category: "index")
    static let search  = Logger(subsystem: subsystem, category: "search")
    static let scanner = Logger(subsystem: subsystem, category: "scanner")
    static let parser  = Logger(subsystem: subsystem, category: "parser")
    static let context = Logger(subsystem: subsystem, category: "workspace-context")
}

// MARK: - Login item

/// Wraps `SMAppService.mainApp` (macOS 13+) so SymbolScan can register itself to launch at login —
/// the "consistently launch it" half of T24. Meaningful only for an **installed** build: a login
/// item registered from a DerivedData/Xcode path points at a location macOS won't relaunch, so pair
/// this with `scripts/install.sh` (which puts SymbolScan.app in /Applications). Lives here so it
/// builds without a project-file edit, like `StatusItemController` below.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register/unregister the app as a login item. Returns the resulting enabled state; on failure
    /// it logs and returns the unchanged state so the menu checkmark stays truthful.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}

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
    /// The trigger-rebinding window, created lazily on first open and retained across closes.
    private var preferencesWindowController: PreferencesWindowController?
    /// Watches the active repo and drives incremental reindex-on-save. Re-pointed whenever the
    /// active repo changes (there is exactly one active repo, so one watcher at a time).
    private var repoWatcher: RepoWatcher?
    /// The local-LLM transport for the ⌘E "explain symbol" flow. Owns a lazily-spawned llama-server;
    /// no process starts until the first explain, and it's torn down on quit.
    private var llmClient: LlamaServerClient?
    /// Provisions the model (first-run background download). Started on launch so it's usually ready
    /// before the first ⌘E; observed by the picker + menu bar for progress.
    private var modelProvisioner: ModelProvisioner?
    /// Resolves Codex's project selector into a verified git root after a hotkey invocation.
    private let workspaceContextDetector = WorkspaceContextDetector()
    /// Invalidates a late AX result after a newer hotkey or explicit manual repository selection.
    private var workspaceContextRequestID = 0

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
        // A restored/recent repo that turns out not to be a usable git repo forgets itself, so we
        // don't keep retrying a dead path every launch.
        index.onRepoInvalid = { url in RepoPreference.clear(url) }
        let llm = LlamaServerClient()
        llmClient = llm
        // Kick off the one-time model download in the background so it's usually ready before the
        // first ⌘E (the turnkey bar). No-ops if the model is already on disk. Skipped on Intel — the
        // bundled runtime is Apple-Silicon-only, so there's no point pulling a ~2 GB model there.
        let provisioner = ModelProvisioner()
        modelProvisioner = provisioner
        if LLMRuntime.isSupported {
            provisioner.start()
        }
        let controller = OverlayWindowController(index: index, llmClient: llm, provisioner: provisioner)
        overlayWindowController = controller
        controller.onChooseRepo = { [weak self] in self?.chooseRepo() }
        controller.onReindex = { [weak self] in self?.reindex() }

        statusItem = StatusItemController(
            index: index,
            provisioner: provisioner,
            onChooseRepo: { [weak self] in self?.chooseRepo() },
            onReindex: { [weak self] in self?.reindex() },
            onSwitch: { [weak self] url in self?.switchTo(url) },
            onOpenHotkeys: { [weak self] in self?.openHotkeys() },
            onSetAutomaticDetection: { [weak self] enabled in
                AutomaticRepoDetectionPreference.setEnabled(enabled)
                if !enabled { self?.workspaceContextRequestID &+= 1 }
            }
        )

        eventTap = EventTap { [weak self] match in
            guard let self else { return }
            self.openPicker(match: match)
        }
        eventTap?.start()

        // Restore the last active repo. If a cache exists it loads instantly; otherwise it scans in
        // the background (non-blocking). A dead/non-git path is forgotten via `onRepoInvalid`.
        if let active = RepoPreference.loadActive() {
            activateRepo(active, source: .restored)
        }
    }

    // MARK: - Repo commands

    private enum RepoActivationSource {
        case manual
        case automatic
        case restored
    }

    /// Open immediately, then run one traced AX probe against the app that owned focus. Detection
    /// never runs on a timer or application-activation event; the global hotkey is its only trigger.
    private func openPicker(match: HotkeyMatch) {
        workspaceContextRequestID &+= 1
        let requestID = workspaceContextRequestID
        let frontmost = NSWorkspace.shared.frontmostApplication
        overlayWindowController?.show(match: match, targetApp: frontmost)

        guard AutomaticRepoDetectionPreference.isEnabled(),
              let app = frontmost,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleIdentifier = app.bundleIdentifier else { return }
        let identity = RunningAppIdentity(processIdentifier: app.processIdentifier,
                                          bundleIdentifier: bundleIdentifier,
                                          localizedName: app.localizedName)
        guard workspaceContextDetector.supports(identity) else { return }

        let knownRoots = ([symbolIndex?.indexedRepoRoot].compactMap { $0 }
                          + RepoPreference.loadRecents())
        workspaceContextDetector.detect(app: identity, knownRoots: knownRoots, trace: true) {
            [weak self] root in
            DispatchQueue.main.async {
                guard let self, self.workspaceContextRequestID == requestID, let root else { return }
                self.activateRepo(root, source: .automatic)
            }
        }
    }

    /// One path for restore, menu/picker choices, and AX detection keeps index + watcher state in
    /// lockstep. Automatic roots are session-only so temporary worktrees do not replace the user's
    /// durable manual fallback or fill the Recent Repos menu.
    private func activateRepo(_ url: URL, source: RepoActivationSource) {
        let root = RepoCandidateResolver.canonical(url)
        if case .manual = source {
            workspaceContextRequestID &+= 1
            RepoPreference.setActive(root)
        }

        let previousRoot = symbolIndex?.indexedRepoRoot
        guard RepoActivationPolicy.shouldActivate(current: previousRoot,
                                                  candidate: root) else { return }
        symbolIndex?.activateRepo(root)
        retargetWatcher(to: root)
    }

    /// Point the file watcher at `root` (stopping any previous one) so saves there trigger an
    /// incremental reindex. Called after every `activateRepo`. Not started under the XCTest host —
    /// the early return in `applicationDidFinishLaunching` keeps `chooseRepo`/`switchTo` and the
    /// restore path from running in tests.
    private func retargetWatcher(to root: URL) {
        repoWatcher?.stop()
        guard let index = symbolIndex else { repoWatcher = nil; return }
        let watcher = RepoWatcher(root: root) { change in
            // RepoWatcher delivers on the main queue; SymbolIndex is @MainActor.
            MainActor.assumeIsolated {
                switch change {
                case .files(let urls): index.filesChanged(urls)
                case .rescan:          index.rescanRequested()
                }
            }
        }
        repoWatcher = watcher
        watcher.start()
    }

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

        activateRepo(url, source: .manual)
    }

    /// Rescan the active repo from scratch (bypassing the cache).
    private func reindex() {
        guard let root = symbolIndex?.indexedRepoRoot ?? RepoPreference.loadActive() else { return }
        symbolIndex?.reindex(root)
    }

    /// Switch to an already-known repo (from the recents menu).
    private func switchTo(_ url: URL) {
        activateRepo(url, source: .manual)
    }

    /// Open (or re-focus) the trigger-rebinding window. Edits persist via `HotkeyPreference` and
    /// live-reload into the running tap; while the recorder captures, the tap is suspended so a
    /// still-bound combo doesn't pop the overlay.
    private func openHotkeys() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                onChange: { [weak self] binding in
                    HotkeyPreference.save(binding)
                    self?.eventTap?.updateBinding(binding)
                },
                onRecording: { [weak self] suspended in
                    self?.eventTap?.recordingSuspended = suspended
                }
            )
        }
        preferencesWindowController?.show()
    }

    private func requestPermissions() {
        // Accessibility — required for the global CGEventTap, text injection, and the bounded AX
        // lookup that identifies the active Codex project when the hotkey is invoked.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.app.warning("Accessibility permission not granted. Hotkey, injection, and automatic repo detection will not work.")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Persist any buffered incremental cache writes before we exit, so a quit mid-debounce doesn't
    /// drop the last few saves' worth of index updates (T23). The in-memory index is always current;
    /// this just keeps the on-disk cache from lagging across a restart.
    func applicationWillTerminate(_ notification: Notification) {
        symbolIndex?.flushPendingWrites()
    }

    /// Terminate any running `llama-server` **before** the process exits. `applicationWillTerminate`
    /// is too late — it returns and the app can exit before an unstructured `Task` is ever scheduled,
    /// orphaning a multi-GB child that keeps the port. So defer termination: return `.terminateLater`,
    /// await the shutdown, then let AppKit proceed. When no client/server exists this is a no-op that
    /// still resolves immediately.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let llm = llmClient else { return .terminateNow }
        Task { @MainActor in
            await llm.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Status item

/// The menu-bar presence: the app's only durable UI (it's `.accessory`, so no dock icon and,
/// before this, no way to quit). Rebuilds its menu on open so the header/count stay live. Lives in
/// this file so it builds without a project-file edit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let index: SymbolIndex
    private let provisioner: ModelProvisioner
    private let onChooseRepo: () -> Void
    private let onReindex: () -> Void
    private let onSwitch: (URL) -> Void
    private let onOpenHotkeys: () -> Void
    private let onSetAutomaticDetection: (Bool) -> Void
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init(index: SymbolIndex,
         provisioner: ModelProvisioner,
         onChooseRepo: @escaping () -> Void,
         onReindex: @escaping () -> Void,
         onSwitch: @escaping (URL) -> Void,
         onOpenHotkeys: @escaping () -> Void,
         onSetAutomaticDetection: @escaping (Bool) -> Void) {
        self.index = index
        self.provisioner = provisioner
        self.onChooseRepo = onChooseRepo
        self.onReindex = onReindex
        self.onSwitch = onSwitch
        self.onOpenHotkeys = onOpenHotkeys
        self.onSetAutomaticDetection = onSetAutomaticDetection
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
            refreshStatusButton()   // initial tooltip
        }

        // Keep the menu-bar icon/tooltip live as the active repo indexes/finishes, without needing
        // to open the menu. `objectWillChange` fires before the value settles, so hop to the next
        // runloop turn (by which point `isIndexing`/`symbolCount` reflect the new state).
        index.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusButton() }
            .store(in: &cancellables)

        // Keep the tooltip's model-download line live as the background fetch progresses.
        provisioner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusButton() }
            .store(in: &cancellables)

        // A full menu bar (e.g. behind a MacBook notch) makes macOS hide overflow items with no
        // API to force placement. Detect it and tell the user about the keyboard fallbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let button = self?.statusItem.button,
                  let window = button.window,
                  !window.occlusionState.contains(.visible) else { return }
            Log.app.warning("""
            SymbolScan's menu-bar icon is hidden (menu bar full / notch). \
            Use the picker overlay instead: ⌘O choose repo, ⌘R reindex, ⌘Q quit.
            """)
        }
    }

    /// Reflect the active repo's state in the menu-bar button's tooltip so progress is visible on
    /// hover without opening the menu. Tooltip-only on purpose: mutating the button *image* live
    /// forces a status-bar relayout that can re-enter layout (`_NSDetectedLayoutRecursion`).
    private func refreshStatusButton() {
        var tip = StatusMenuModel.title(repo: index.indexedRepoRoot,
                                        count: index.symbolCount,
                                        isIndexing: index.isIndexing,
                                        error: index.lastIndexError)
        if let modelLine = ModelStatusCopy.line(for: provisioner.state) {
            tip += " · \(modelLine)"
        }
        statusItem.button?.toolTip = tip
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

        // Ambient model-download status (only while downloading or after a failure).
        if let modelLine = ModelStatusCopy.line(for: provisioner.state) {
            let modelItem = NSMenuItem(title: modelLine, action: nil, keyEquivalent: "")
            modelItem.isEnabled = false
            menu.addItem(modelItem)
        }
        menu.addItem(.separator())

        let choose = NSMenuItem(title: "Choose Repo…", action: #selector(chooseRepo), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let reindex = NSMenuItem(title: "Reindex", action: #selector(reindexRepo), keyEquivalent: "r")
        reindex.target = self
        reindex.isEnabled = index.indexedRepoRoot != nil && !index.isIndexing
        menu.addItem(reindex)

        menu.addItem(.separator())
        let hotkeys = NSMenuItem(title: "Hotkeys…", action: #selector(openHotkeys), keyEquivalent: "")
        hotkeys.target = self
        menu.addItem(hotkeys)

        let automatic = NSMenuItem(title: "Detect Repo Automatically",
                                   action: #selector(toggleAutomaticDetection), keyEquivalent: "")
        automatic.target = self
        automatic.state = AutomaticRepoDetectionPreference.isEnabled() ? .on : .off
        menu.addItem(automatic)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

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
    @objc private func openHotkeys() { onOpenHotkeys() }

    @objc private func toggleAutomaticDetection() {
        onSetAutomaticDetection(!AutomaticRepoDetectionPreference.isEnabled())
    }

    /// Menu rebuilds on every open (`menuNeedsUpdate`), so the checkmark re-reads `LoginItem.isEnabled`
    /// next time — no need to mutate the item here beyond flipping the registration.
    @objc private func toggleLoginItem() { LoginItem.setEnabled(!LoginItem.isEnabled) }
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

// MARK: - Preferences window

/// Hosts the SwiftUI `HotkeySettingsView` in a hand-managed window. Like everything else in this
/// `.accessory` app, the window is managed manually (no SwiftUI `Settings` scene, which is awkward
/// to open programmatically from a menu-bar-only app) and reuses the overlay's activation dance so
/// it can take key focus — the key recorder receives no `keyDown` otherwise. Lives here so it builds
/// without a project-file edit.
@MainActor
final class PreferencesWindowController: NSWindowController {
    init(onChange: @escaping (HotkeyBinding) -> Void,
         onRecording: @escaping (Bool) -> Void) {
        let root = HotkeySettingsView(onChange: onChange, onRecording: onRecording)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SymbolScan Hotkeys"
        window.isReleasedWhenClosed = false   // we retain + reuse this controller
        window.contentView = NSHostingView(rootView: root)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Bring the window forward. An `.accessory` app isn't active by default, so activate or the
    /// window opens behind other apps and can't become key (same handling as the overlay).
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
