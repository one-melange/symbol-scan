import AppKit
import ApplicationServices
import Foundation
import os

/// Keeps SymbolScan's active repository aligned with the supported coding app while the picker is
/// either visible or hidden. AX notifications provide low-latency hints; polling is the correctness
/// fallback because Electron does not consistently publish selection/layout changes through AX.
@MainActor
final class WorkspaceContextMonitor {
    enum ScanReason: String {
        case activation
        case accessibility
        case polling
        case overlayOpened
    }

    private let detector: WorkspaceContextDetector
    private let knownRoots: () -> [URL]
    private let onResolvedRoot: (URL, String?) -> Void
    private let pollInterval: TimeInterval
    private let eventDebounce: TimeInterval

    private var workspaceTokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var axObserver: AXWorkspaceChangeObserver?
    private var frontmostTarget: NSRunningApplication?
    private var overlayTarget: NSRunningApplication?
    private var overlayVisible = false
    private var pendingScan: DispatchWorkItem?
    private var pendingTrace = false
    private var scanInFlight = false
    private var rescanAfterCurrent = false
    private var generation = 0
    private var started = false

    init(detector: WorkspaceContextDetector,
         pollInterval: TimeInterval = 0.8,
         eventDebounce: TimeInterval = 0.18,
         knownRoots: @escaping () -> [URL],
         onResolvedRoot: @escaping (URL, String?) -> Void) {
        self.detector = detector
        self.pollInterval = pollInterval
        self.eventDebounce = eventDebounce
        self.knownRoots = knownRoots
        self.onResolvedRoot = onResolvedRoot
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.applicationActivated(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.applicationTerminated(app) }
            },
        ]
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            applicationActivated(frontmost)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(center.removeObserver)
        workspaceTokens.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pendingScan?.cancel()
        pendingScan = nil
        pendingTrace = false
        rescanAfterCurrent = false
        axObserver = nil
    }

    func setEnabled(_ enabled: Bool) {
        pendingScan?.cancel()
        pendingScan = nil
        pendingTrace = false
        rescanAfterCurrent = false
        generation &+= 1
        if enabled, let frontmost = NSWorkspace.shared.frontmostApplication {
            applicationActivated(frontmost)
        } else if !enabled {
            axObserver = nil
        }
    }

    /// Pin the original coding app while SymbolScan itself becomes frontmost. The trace is attached
    /// to this scan so every hotkey invocation remains useful for local AX reverse-engineering.
    func overlayDidOpen(targetApp: NSRunningApplication?) {
        overlayVisible = true
        guard let targetApp, supports(targetApp) else {
            clearTarget()
            return
        }
        overlayTarget = targetApp
        frontmostTarget = targetApp
        observe(targetApp)
        scheduleScan(reason: .overlayOpened, trace: true)
    }

    func overlayDidClose() {
        overlayVisible = false
        overlayTarget = nil
        if let frontmost = NSWorkspace.shared.frontmostApplication, supports(frontmost) {
            frontmostTarget = frontmost
            observe(frontmost)
            scheduleScan(reason: .activation)
        }
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        guard AutomaticRepoDetectionPreference.isEnabled() else { return }
        if supports(app) {
            frontmostTarget = app
            if overlayVisible { overlayTarget = app }
            observe(app)
            scheduleScan(reason: .activation)
        } else if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            // Unsupported frontmost apps retain the already-active repo but stop monitoring the
            // previous coding app. SymbolScan itself is ignored so opening the overlay does not
            // discard the target captured immediately beforehand.
            clearTarget()
        }
    }

    private func applicationTerminated(_ app: NSRunningApplication) {
        guard app.processIdentifier == frontmostTarget?.processIdentifier
                || app.processIdentifier == overlayTarget?.processIdentifier else { return }
        if app.processIdentifier == frontmostTarget?.processIdentifier { frontmostTarget = nil }
        if app.processIdentifier == overlayTarget?.processIdentifier { overlayTarget = nil }
        axObserver = nil
        pendingScan?.cancel()
        pendingScan = nil
        rescanAfterCurrent = false
        generation &+= 1
    }

    private func poll() {
        guard AutomaticRepoDetectionPreference.isEnabled(), pendingScan == nil, !scanInFlight,
              currentTarget() != nil else { return }
        scheduleScan(reason: .polling)
    }

    private func supports(_ app: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = app.bundleIdentifier else { return false }
        return detector.supports(RunningAppIdentity(processIdentifier: app.processIdentifier,
                                                    bundleIdentifier: bundleIdentifier,
                                                    localizedName: app.localizedName))
    }

    private func currentTarget() -> NSRunningApplication? {
        let target = overlayVisible ? (overlayTarget ?? frontmostTarget) : frontmostTarget
        guard let target, !target.isTerminated, supports(target) else { return nil }
        return target
    }

    private func clearTarget() {
        frontmostTarget = nil
        overlayTarget = nil
        axObserver = nil
        pendingScan?.cancel()
        pendingScan = nil
        pendingTrace = false
        rescanAfterCurrent = false
        generation &+= 1
    }

    private func observe(_ app: NSRunningApplication) {
        guard axObserver?.processIdentifier != app.processIdentifier else { return }
        axObserver = AXWorkspaceChangeObserver(processIdentifier: app.processIdentifier) {
            [weak self] notification in
            guard let self else { return }
            Log.context.debug("AX workspace change hint: \(notification, privacy: .public)")
            self.scheduleScan(reason: .accessibility)
        }
    }

    private func scheduleScan(reason: ScanReason, trace: Bool = false) {
        guard AutomaticRepoDetectionPreference.isEnabled(), currentTarget() != nil else { return }
        if reason == .polling, pendingScan != nil { return }

        pendingTrace = pendingTrace || trace
        if scanInFlight {
            // Invalidate the running result and collapse any number of AX hints into one follow-up
            // scan. The detector has a serial queue, so this prevents an event storm from building
            // a backlog of snapshots for obsolete UI states.
            rescanAfterCurrent = true
            generation &+= 1
            return
        }
        pendingScan?.cancel()
        generation &+= 1
        let scheduledGeneration = generation
        let delay = reason == .accessibility ? eventDebounce : 0
        let work = DispatchWorkItem { [weak self] in
            self?.performScan(generation: scheduledGeneration, reason: reason)
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performScan(generation scheduledGeneration: Int, reason: ScanReason) {
        guard scheduledGeneration == generation else { return }
        pendingScan = nil
        guard let app = currentTarget(), let bundleIdentifier = app.bundleIdentifier else { return }
        scanInFlight = true
        let trace = pendingTrace
        pendingTrace = false
        let identity = RunningAppIdentity(processIdentifier: app.processIdentifier,
                                          bundleIdentifier: bundleIdentifier,
                                          localizedName: app.localizedName)
        let appName = detector.displayName(for: identity)
        let roots = knownRoots()
        Log.context.debug("Workspace scan started: \(reason.rawValue, privacy: .public), app=\(bundleIdentifier, privacy: .public), generation=\(scheduledGeneration, privacy: .public)")

        detector.detect(app: identity, knownRoots: roots, trace: trace) { [weak self] root in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                let acceptsResult = WorkspaceMonitorResultPolicy.accepts(
                    generation: scheduledGeneration,
                    currentGeneration: self.generation,
                    targetProcessIdentifier: app.processIdentifier,
                    currentTargetProcessIdentifier: self.currentTarget()?.processIdentifier
                )
                if acceptsResult, let root { self.onResolvedRoot(root, appName) }
                if self.rescanAfterCurrent {
                    self.rescanAfterCurrent = false
                    self.scheduleScan(reason: .accessibility)
                }
            }
        }
    }
}

/// Pure stale-result guard kept separate from AppKit so rapid project/app transitions can be
/// regression-tested without constructing live `NSRunningApplication` or AX objects.
nonisolated enum WorkspaceMonitorResultPolicy {
    static func accepts(generation: Int, currentGeneration: Int,
                        targetProcessIdentifier: pid_t,
                        currentTargetProcessIdentifier: pid_t?) -> Bool {
        generation == currentGeneration
            && targetProcessIdentifier == currentTargetProcessIdentifier
    }
}

/// Lightweight AX event hinting. Notifications are registered on the application element; apps
/// that do not propagate descendant changes are still covered by `WorkspaceContextMonitor` polling.
@MainActor
private final class AXWorkspaceChangeObserver {
    let processIdentifier: pid_t
    private let onChange: (String) -> Void
    private let appElement: AXUIElement
    private var observer: AXObserver?

    init?(processIdentifier: pid_t, onChange: @escaping (String) -> Void) {
        self.processIdentifier = processIdentifier
        self.onChange = onChange
        self.appElement = AXUIElementCreateApplication(processIdentifier)

        var created: AXObserver?
        guard AXObserverCreate(processIdentifier, workspaceAXObserverCallback, &created) == .success,
              let created else { return nil }
        observer = created

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedWindowChangedNotification as String,
            kAXFocusedUIElementChangedNotification as String,
            kAXWindowCreatedNotification as String,
            kAXTitleChangedNotification as String,
            kAXValueChangedNotification as String,
            kAXSelectedChildrenChangedNotification as String,
            kAXLayoutChangedNotification as String,
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(created, appElement, notification as CFString, pointer)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                                  .commonModes)
        }
    }

    fileprivate func received(_ notification: String) {
        onChange(notification)
    }
}

nonisolated private func workspaceAXObserverCallback(_ observer: AXObserver,
                                                     _ element: AXUIElement,
                                                     _ notification: CFString,
                                                     _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let owner = Unmanaged<AXWorkspaceChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    let notificationName = notification as String
    DispatchQueue.main.async {
        owner.received(notificationName)
    }
}
