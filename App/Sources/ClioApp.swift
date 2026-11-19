import SwiftUI
import UserNotifications

/// Shows a Bot's notification even while the app is open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notify.registerCategories()
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

    init() { Pref.settleType() }

    var body: some Scene {
        WindowGroup {
            ClioRoot().appLock()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// The same color, darker (`amount` below 1) or mixed toward white (`lift` above 0).
    static func shade(_ hex: UInt32, amount: Double = 1, lift: Double = 0) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255 * amount
            return min(1, value + (1 - value) * lift)
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}
