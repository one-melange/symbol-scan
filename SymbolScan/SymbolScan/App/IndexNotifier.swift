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

    /// `UNUserNotificationCenter.current()` traps if there's no main bundle proxy (e.g. some test
    /// hosts). Guard on a bundle identifier so unit tests don't crash.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
