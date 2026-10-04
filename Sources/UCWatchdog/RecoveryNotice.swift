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

    static func content(for incident: RecoveryIncident, preview: Bool = false,
                        language: AppLanguage = .current) -> UNMutableNotificationContent? {
        guard let end = incident.restoredAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        formatter.dateFormat = "dd.MM HH:mm:ss"
        let seconds = Int(max(0, end - incident.startedAt).rounded())
        let content = UNMutableNotificationContent()
        content.title = preview
            ? localized("Notification Test", "Проверка уведомления", language: language)
            : localized("Connection Restored", "Связь восстановлена", language: language)
        let start = formatter.string(from: Date(timeIntervalSince1970: incident.startedAt))
        let restored = formatter.string(from: Date(timeIntervalSince1970: end))
        content.body = localized("Disconnected: \(start)\nRestored: \(restored)\nOffline: \(seconds) s. ",
                                 "Обрыв: \(start)\nВосстановление: \(restored)\nБез связи: \(seconds) с. ", language: language)
            + (incident.restartAttempted
                ? localized("Watchdog attempted recovery.", "Watchdog запускал восстановление.", language: language)
                : localized("The connection returned without a watchdog restart.", "Связь вернулась без перезапуска watchdog.", language: language))
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
