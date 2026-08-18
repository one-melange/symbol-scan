import AppKit

/// Keeps the active repo aligned with Codex. A small periodic probe is more predictable than
/// observing broad Electron AX notifications, which frequently fire for unrelated page changes.
@MainActor
final class WorkspaceContextMonitor {
    private let detector: WorkspaceContextDetector
    private let knownRoots: () -> [URL]
    private let onResolvedRoot: (URL, String?) -> Void
    private let pollInterval: TimeInterval

    private var activationToken: NSObjectProtocol?
    private var terminationToken: NSObjectProtocol?
    private var timer: Timer?
    private var target: NSRunningApplication?
    private var scanInFlight = false
    private var scanRequested = false
    private var traceRequested = false
    private var started = false

    init(detector: WorkspaceContextDetector,
         pollInterval: TimeInterval = 0.8,
         knownRoots: @escaping () -> [URL],
         onResolvedRoot: @escaping (URL, String?) -> Void) {
        self.detector = detector
        self.pollInterval = pollInterval
        self.knownRoots = knownRoots
        self.onResolvedRoot = onResolvedRoot
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        activationToken = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                             object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.applicationActivated(app) }
        }
        terminationToken = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if app.processIdentifier == self?.target?.processIdentifier { self?.clearTarget() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in MainActor.assumeIsolated { self?.scan() }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            applicationActivated(frontmost)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        let center = NSWorkspace.shared.notificationCenter
        if let activationToken { center.removeObserver(activationToken) }
        if let terminationToken { center.removeObserver(terminationToken) }
        activationToken = nil
        terminationToken = nil
        timer?.invalidate()
        timer = nil
        clearTarget()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, let frontmost = NSWorkspace.shared.frontmostApplication {
            applicationActivated(frontmost)
        } else if !enabled {
            clearTarget()
        }
    }

    /// SymbolScan becomes frontmost when the picker opens, so retain the Codex process captured
    /// immediately beforehand and request the concise Debug trace from this scan.
    func overlayDidOpen(targetApp: NSRunningApplication?) {
        guard let targetApp, supports(targetApp) else {
            clearTarget()
            return
        }
        target = targetApp
        scan(trace: true)
    }

    func overlayDidClose() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, supports(frontmost) {
            target = frontmost
            scan()
        }
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        guard AutomaticRepoDetectionPreference.isEnabled() else { return }
        if supports(app) {
            target = app
            scan()
        } else if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            // Unsupported apps keep the active repo but stop Codex monitoring.
            clearTarget()
        }
    }

    private func supports(_ app: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = app.bundleIdentifier else { return false }
        return detector.supports(RunningAppIdentity(processIdentifier: app.processIdentifier,
                                                    bundleIdentifier: bundleIdentifier,
                                                    localizedName: app.localizedName))
    }

    private func scan(trace: Bool = false) {
        guard AutomaticRepoDetectionPreference.isEnabled(),
              let app = target, !app.isTerminated,
              let bundleIdentifier = app.bundleIdentifier else { return }
        traceRequested = traceRequested || trace
        if scanInFlight {
            scanRequested = true
            return
        }

        scanInFlight = true
        let shouldTrace = traceRequested
        traceRequested = false
        let processIdentifier = app.processIdentifier
        let identity = RunningAppIdentity(processIdentifier: processIdentifier,
                                          bundleIdentifier: bundleIdentifier,
                                          localizedName: app.localizedName)
        let appName = detector.displayName(for: identity)
        detector.detect(app: identity, knownRoots: knownRoots(), trace: shouldTrace) {
            [weak self] root in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                if WorkspaceMonitorResultPolicy.accepts(
                    targetProcessIdentifier: processIdentifier,
                    currentTargetProcessIdentifier: self.target?.processIdentifier
                ), let root {
                    self.onResolvedRoot(root, appName)
                }
                if self.scanRequested {
                    self.scanRequested = false
                    self.scan()
                }
            }
        }
    }

    private func clearTarget() {
        target = nil
        scanRequested = false
        traceRequested = false
    }
}

nonisolated enum WorkspaceMonitorResultPolicy {
    static func accepts(targetProcessIdentifier: pid_t,
                        currentTargetProcessIdentifier: pid_t?) -> Bool {
        targetProcessIdentifier == currentTargetProcessIdentifier
    }
}
