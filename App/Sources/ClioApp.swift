import SwiftUI
import UserNotifications

/// Shows a Bot's notification even while the app is open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        InteractivePreviewRotation.supported(for: window)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notify.registerCategories()
        MemoryNight.register()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapping a companion's notification opens that conversation; 同意 / 不同意 answers an approval;
    /// `clio.question` replies commit Phase 1 (`.answered`) atomically before routing resume.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = info["approval"] as? String, ["allow", "deny"].contains(response.actionIdentifier) {
            let allow = response.actionIdentifier == "allow"
            await MainActor.run {
                ChatNotificationRoute.enqueue(.answer(id, allow))
            }
            return
        }
        if let questionID = info["question"] as? String, !questionID.isEmpty,
           ["reply_question", "option_0", "option_1"].contains(response.actionIdentifier) {
            let answerText: String?
            if response.actionIdentifier == "reply_question",
               let textResponse = response as? UNTextInputNotificationResponse {
                answerText = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if response.actionIdentifier == "option_0",
                      let options = info["options"] as? [String], options.indices.contains(0) {
                answerText = options[0]
            } else if response.actionIdentifier == "option_1",
                      let options = info["options"] as? [String], options.indices.contains(1) {
                answerText = options[1]
            } else {
                answerText = nil
            }
            if let answerText, !answerText.isEmpty {
                let answerID = UUID().uuidString.lowercased()
                let persisted = (try? SubtaskManager.sharedCanonicalStore.recordQuestionAnswer(
                    questionID: questionID,
                    answerText: answerText,
                    answerID: answerID,
                    fromBackgroundNotification: true
                )) != nil
                if persisted {
                    await MainActor.run {
                        ChatNotificationRoute.enqueue(.answerQuestion(questionID, answerID, answerText))
                    }
                }
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
        case answerQuestion(String, String, String)
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
        // Reconcile any interrupted backup directory swap BEFORE any store touches `Disk.root`
        // or creates empty skeleton folders (`Team/chats`, `Team/subtasks`, etc.).
        if !Backup.reconcileInterruptedRestoreBeforeStorageInit() {
            Disk.frozen = true
        }
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
