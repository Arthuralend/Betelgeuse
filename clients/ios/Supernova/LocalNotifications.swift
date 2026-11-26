import Foundation
import UserNotifications
import UIKit

enum LocalNotifications {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func incomingMessage(from name: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "Новое сообщение"
        content.sound = .default
        content.badge = NSNumber(value: 1)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func incomingCall(from name: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Входящий звонок"
        content.body = name
        content.sound = .defaultRingtone
        content.badge = NSNumber(value: 1)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
