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
                ChatNotificationRoute.enqueue(.answer(id, allow))
            }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let chat = info["chat"] as? String, !chat.isEmpty else { return }
        await MainActor.run {
            ChatNotificationRoute.enqueue(.open(chat))
        }
    }
}

/// A cold launch can receive the tap before Desk subscribes.
@MainActor
enum ChatNotificationRoute {
    enum Action {
        case open(String)
        case answer(String, Bool)
    }

    private static var pending: [Action] = []

    static func enqueue(_ action: Action) {
        pending.append(action)
        NotificationCenter.default.post(name: .clioOpenChat, object: nil)
    }

    static func take() -> [Action] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

extension Notification.Name {
    /// Object: a chat key, `bot-…` or `room-…`.
    static let clioOpenChat = Notification.Name("clio.openChat")
}

@main
struct ClioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Pref.settleType()
        L.prepare()
        FontShelf.shared.prepare()
        SearchEngine.install()
        // What models can do, from the open catalog; at most once a day, in the background.
        Task.detached(priority: .background) { await ModelsDev.refreshIfStale() }
    }

    var body: some Scene {
        WindowGroup {
            ClioRoot().appLock()
        }
    }
}
