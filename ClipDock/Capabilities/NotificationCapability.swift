// NotificationCapability.swift
// Shared local notification capability — schedule UNUserNotification
//
// Used by: IOSSystemBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import Foundation
import UserNotifications

@MainActor
final class NotificationCapability {

    /// Send a local notification with title and body.
    /// Requests authorization if not yet granted.
    func send(title: String, body: String) async throws {
        let center = UNUserNotificationCenter.current()
        try await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }
}
