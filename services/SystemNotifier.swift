import Foundation
import UserNotifications

final class SystemNotifier: NSObject {
    @MainActor static let shared = SystemNotifier()
    private var bootstrapped = false

    @MainActor func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    // MARK: - Public API
    @MainActor func notify(title: String, body: String) async {
        await notify(title: title, body: body, threadId: nil)
    }

    @MainActor func notify(title: String, body: String, threadId: String?) async {
        let center = UNUserNotificationCenter.current()
        // Ensure we have requested permission at least once
        bootstrap()
        // Query settings to decide if we need a fallback
        let status = await SystemNotifier.authorizationStatus()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let threadId { content.threadIdentifier = threadId }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        )
        do {
            try await center.add(request)
        } catch {
            // Fallback to AppleScript if UNUserNotifications fails
            Self.notifyViaOSAScript(title: title, body: body)
            return
        }
        // If not authorized to show alerts, attempt fallback so user still gets a toast
        if status != .authorized {
            Self.notifyViaOSAScript(title: title, body: body)
        }
    }

    // Specialized helper: agent completed and awaits user follow-up.
    // Also posts an in-app notification to update list indicators.
    @MainActor func notifyAgentCompleted(sessionID: String, message: String) async {
        await notify(title: "CodMate", body: message, threadId: "agent")
        NotificationCenter.default.post(
            name: .codMateAgentCompleted,
            object: nil,
            userInfo: ["sessionID": sessionID, "message": message]
        )
    }

    // MARK: - Internals
    private static func notifyViaOSAScript(title: String, body: String) {
        let script = "display notification \"\(body.replacingOccurrences(of: "\\\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title.replacingOccurrences(of: "\\\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

nonisolated extension SystemNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Call completion handler directly without actor hop to avoid sending non-Sendable closure
        completionHandler([.banner, .list, .sound])
    }
}

extension Notification.Name {
  static let codMateAgentCompleted = Notification.Name("CodMate.AgentCompleted")
  static let codMateStartEmbeddedNewProject = Notification.Name("CodMate.StartEmbeddedNewProject")
  static let codMateStartEmbeddedNewSession = Notification.Name("CodMate.StartEmbeddedNewSession")
  static let codMateToggleSidebar = Notification.Name("CodMate.ToggleSidebar")
  static let codMateToggleList = Notification.Name("CodMate.ToggleList")
  static let codMateRepoAuthorizationChanged = Notification.Name("CodMate.RepoAuthorizationChanged")
  static let codMateTerminalExited = Notification.Name("CodMate.TerminalExited")
  static let codMateTerminalSessionsUpdated = Notification.Name("CodMate.TerminalSessionsUpdated")
  static let codMateConversationFilter = Notification.Name("CodMate.ConversationFilter")
  static let codMateFocusGlobalSearch = Notification.Name("CodMate.FocusGlobalSearch")
  static let codMateExpandProjectTree = Notification.Name("CodMate.ExpandProjectTree")
  static let codMateResignQuickSearch = Notification.Name("CodMate.ResignQuickSearch")
  static let codMateQuickSearchFocusBlocked = Notification.Name("CodMate.QuickSearchFocusBlocked")
  static let codMateActiveProviderChanged = Notification.Name("CodMate.ActiveProviderChanged")
  static let codMateResumeSession = Notification.Name("CodMate.ResumeSession")
  static let codMateGlobalRefresh = Notification.Name("CodMate.GlobalRefresh")
  static let codMateOpenMainWindow = Notification.Name("CodMate.OpenMainWindow")
  static let codMateCollapseAllTasks = Notification.Name("CodMate.CollapseAllTasks")
  static let codMateExpandAllTasks = Notification.Name("CodMate.ExpandAllTasks")
  static let codMateOpenSettings = Notification.Name("CodMate.OpenSettings")
  static let codMateFocusSessionSummary = Notification.Name("CodMate.FocusSessionSummary")
  static let codMateOpenNewProject = Notification.Name("CodMate.OpenNewProject")
}
