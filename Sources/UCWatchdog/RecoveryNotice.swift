import Foundation
import UserNotifications

struct RecoveryIncident: Codable {
    var startedAt: Double
    var restoredAt: Double?
    var restartAttempted: Bool
}

final class RecoveryNotice: NSObject, UNUserNotificationCenterDelegate {
    let logger: Logger
    let center: UNUserNotificationCenter?
    var preview = false

    init(logger: Logger, enabled: Bool = true) {
        self.logger = logger
        // UserNotifications requires an application bundle, even for a LaunchAgent.
        center = enabled && Bundle.main.bundleIdentifier == label
            ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
        if enabled && center == nil {
            logger.write("Notifications unavailable: run the executable inside UC Watchdog.app (see bundle/install)")
        }
    }

    static func content(for incident: RecoveryIncident, preview: Bool = false) -> UNMutableNotificationContent? {
        guard let end = incident.restoredAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm:ss"
        let seconds = Int(max(0, end - incident.startedAt).rounded())
        let content = UNMutableNotificationContent()
        content.title = preview ? "Проверка уведомления" : "Связь восстановлена"
        content.body = "Обрыв: \(formatter.string(from: Date(timeIntervalSince1970: incident.startedAt)))\n"
            + "Восстановление: \(formatter.string(from: Date(timeIntervalSince1970: end)))\n"
            + "Без связи: \(seconds) с. "
            + (incident.restartAttempted ? "Watchdog запускал восстановление." : "Связь вернулась без перезапуска watchdog.")
        content.threadIdentifier = preview ? "preview" : "recovery"
        return content
    }

    func authorize() {
        center?.requestAuthorization(options: [.alert]) { [logger] granted, error in
            if let error { logger.write("Notification authorization failed: \(error)") }
            else { logger.write("Notification permission granted=\(granted)") }
        }
    }

    func recovered(_ incident: RecoveryIncident) {
        guard let center, let content = Self.content(for: incident, preview: preview) else { return }
        // Check authorization again so a change in System Settings takes effect without a restart.
        center.getNotificationSettings { [logger, preview] settings in
            guard settings.authorizationStatus == .authorized else {
                logger.write("Recovery notification skipped: permission not granted")
                return
            }
            let identifier = preview ? "preview-\(UUID().uuidString)" : "recovery-\(incident.startedAt)"
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error { logger.write("Cannot submit recovery notification: \(error)") }
                else { logger.write("Recovery notification submitted id=\(identifier)") }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
