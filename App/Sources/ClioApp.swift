import SwiftUI
import UserNotifications

/// Shows a Bot's notification even while the app is open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notify.registerCategories()
        MemoryNight.register()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapping a companion's notification opens that conversation; 同意 / 不同意 on an approval answers it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = info["approval"] as? String, ["allow", "deny"].contains(response.actionIdentifier) {
            let allow = response.actionIdentifier == "allow"
            await MainActor.run {
                NotificationCenter.default.post(name: .clioAnswerApproval, object: id, userInfo: ["allow": allow])
            }
            return
        }
        guard let chat = info["chat"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .clioOpenChat, object: chat)
        }
    }
}

extension Notification.Name {
    /// Object: a chat key, `bot-…` or `room-…`.
    static let clioOpenChat = Notification.Name("clio.openChat")
    /// Object: an approval id; userInfo `allow`: Bool. Answered from a notification.
    static let clioAnswerApproval = Notification.Name("clio.answerApproval")
}

@main
struct ClioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Pref.settleType()
        L.prepare()
        FontShelf.shared.prepare()
        // What models can do, from the open catalog; at most once a day, in the background.
        Task.detached(priority: .background) { await ModelsDev.refreshIfStale() }
    }

    var body: some Scene {
        WindowGroup {
            ClioRoot().appLock()
        }
    }
}
