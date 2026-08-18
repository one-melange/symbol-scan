import Foundation
import UserNotifications
import os

/// Posts a local notification banner when a real index scan finishes, so the user knows a
/// long-running background index (e.g. a large repo) completed without watching the menu bar.
///
/// Cache-hit repo switches are intentionally silent — only a genuine re-parse notifies (see
/// `SymbolIndex.finishJob`). Local notifications need no entitlement; the app is a real bundle.
enum IndexNotifier {

    /// Ask once (typically at launch) for permission to show banners. Safe to call when the app
    /// runs headless/in tests — it just no-ops if the notification center is unavailable.
    static func requestAuthorization() {
        guard let center = center else { return }
        // Automatic repo switches happen immediately before SymbolScan activates its overlay. A
        // delegate is required for the banner to remain visible if delivery races that activation.
        center.delegate = NotificationPresenter.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Log.notify.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post "Indexed <repo> — <n> symbols". No-op if authorization was denied.
    static func notifyIndexed(root: URL, count: Int) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Indexing complete"
        content.body = "Indexed \(root.lastPathComponent) — \(count) symbols"
        let request = UNNotificationRequest(
            identifier: "symbolscan.indexed.\(root.path)",
            content: content,
            trigger: nil   // deliver immediately
        )
        center.add(request) { error in
            if let error { Log.notify.error("Failed to post index notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Post only after automatic context detection actually changes the active root. The caller
    /// owns the persisted opt-out and same-root guard; this function just formats and delivers.
    static func notifyRepoSwitched(from previousRoot: URL?, to root: URL, appName: String?) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = RepoSwitchNotificationCopy.title
        content.body = RepoSwitchNotificationCopy.body(from: previousRoot, to: root,
                                                       appName: appName)
        let request = UNNotificationRequest(
            identifier: "symbolscan.repo-switched.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { Log.notify.error("Failed to post repo-switch notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// `UNUserNotificationCenter.current()` traps if there's no main bundle proxy (e.g. some test
    /// hosts). Guard on a bundle identifier so unit tests don't crash.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}

/// Pure notification copy so the context change is testable without touching Notification Center.
nonisolated enum RepoSwitchNotificationCopy {
    static let title = "SymbolScan switched repositories"

    static func body(from previousRoot: URL?, to root: URL, appName: String?) -> String {
        let source = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = source.flatMap { $0.isEmpty ? nil : $0 }.map { "\($0): " } ?? ""
        if let previousRoot {
            return "\(prefix)\(previousRoot.lastPathComponent) → \(root.lastPathComponent)"
        }
        return "\(prefix)Using \(root.lastPathComponent)"
    }
}

private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
