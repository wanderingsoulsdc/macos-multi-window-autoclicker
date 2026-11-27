import AppKit
import Combine
import OSLog
import UserNotifications

@MainActor
final class RunNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Access { case checking, notRequested, banner, quiet, disabled }

    static let shared = RunNotifications()
    @Published private(set) var access: Access = .checking
    @Published private(set) var requesting = false
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "local.macwindowclicker.app", category: "RunNotifications")
    private let soundURL = Bundle.main.url(forResource: "MultiClick-TaskEnd", withExtension: "wav")
    private lazy var previewSound = soundURL.flatMap { NSSound(contentsOf: $0, byReference: true) }

    private override init() {
        super.init()
        center.delegate = self
    }

    func refresh() async { updateAccess(from: await center.notificationSettings()) }

    var canPreviewSound: Bool { previewSound != nil }

    func playSoundPreview() {
        previewSound?.stop()
        previewSound?.play()
    }

    func requestAccess() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { logger.error("Could not request notification permission.") }
        await refresh()
    }

    func post(_ end: RunEnd, targetName: String, sessionID: UUID) {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            updateAccess(from: settings)
            guard access == .banner || access == .quiet else { return }

            let content = UNMutableNotificationContent()
            content.title = end.title
            content.subtitle = targetName
            content.body = "已发送 \(end.sent) 次操作。" + (end.reason.map { "\n\($0)" } ?? "")
            content.threadIdentifier = sessionID.uuidString
            if settings.soundSetting == .enabled {
                content.sound = soundURL.map {
                    UNNotificationSound(named: UNNotificationSoundName(rawValue: $0.lastPathComponent))
                } ?? .default
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do { try await center.add(request) }
            catch { logger.error("Could not submit a task-end notification.") }
        }
    }

    private func updateAccess(from settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined: access = .notRequested
        case .authorized, .provisional:
            if settings.alertSetting == .enabled { access = .banner }
            else if settings.notificationCenterSetting == .enabled { access = .quiet }
            else { access = .disabled }
        default: access = .disabled
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list, .sound])
    }
}
