import AppKit
import UserNotifications

/// Notification Center banners for messages that name you.
///
/// Only fires when the app is not frontmost. A banner for a line you are
/// already looking at is noise, and this is an app people leave open for
/// hours during a lift.
@MainActor
final class Notifier {

    static let shared = Notifier()
    private init() {}

    private var authorized = false
    private var asked = false

    /// Recently notified mentions, so two windows watching the same room
    /// raise one banner rather than one each. Keyed on sender plus text,
    /// which is what the operator would call "the same message".
    private var recent: [String: Date] = [:]

    /// `UNUserNotificationCenter.current()` traps outright in a process
    /// with no bundle identifier — which is exactly what `swift run
    /// KST2Mac` is. Everything here is a no-op in that case so the app
    /// stays runnable from the command line for development.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available, !asked else { return }
        asked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
    }

    /// - Parameter directed: true when the message was addressed to us
    ///   with `/CQ`, as opposed to merely mentioning our callsign.
    func mention(from: String, name: String?, text: String, room: String, directed: Bool) {
        guard available, authorized, !NSApp.isActive else { return }

        let key = "\(from)|\(text)"
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 30 }
        guard recent[key] == nil else { return }
        recent[key] = now

        let content = UNMutableNotificationContent()
        content.title = directed ? "\(from) → you" : "\(from) mentioned you"
        content.subtitle = [name, room].compactMap { $0 }.joined(separator: " · ")
        content.body = text
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

        NSApp.dockTile.badgeLabel = "!"
    }

    /// Called when a window comes forward — whatever the banner was for
    /// has now been seen.
    func clearBadge() {
        NSApp.dockTile.badgeLabel = nil
    }
}
