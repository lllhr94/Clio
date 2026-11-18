import AppIntents
import SwiftUI

/// What Siri or a shortcut asked for. Each one only opens Clio at the composer: nothing is sent on its own.
enum ShortcutAsk: Equatable {
    /// Open the newest conversation with these words in the composer (maybe none).
    case ask(String)
    /// Open the newest conversation and start listening.
    case dictate
    /// Turn a new leaf with the newest companion and wait at the composer.
    case fresh
}

/// Hands a shortcut's request to the screens. Kept until taken, because a cold start draws the desk after the intent has run.
@MainActor
enum ShortcutDoor {
    /// Waiting for the desk to pick a conversation.
    static var pending: ShortcutAsk?
    /// Waiting for that conversation's page, by chat key.
    static var forChat: [String: ShortcutAsk] = [:]

    static func knock(_ ask: ShortcutAsk) {
        pending = ask
        NotificationCenter.default.post(name: .clioShortcut, object: nil)
    }

    static func take(for key: String) -> ShortcutAsk? { forChat.removeValue(forKey: key) }
}

extension Notification.Name {
    /// Siri or a shortcut asked for something; see `ShortcutDoor`.
    static let clioShortcut = Notification.Name("clio.shortcut")
    /// The desk has picked the conversation; its page takes the request.
    static let clioShortcutReady = Notification.Name("clio.shortcutReady")
}

struct AskClioIntent: AppIntent {
    static let title: LocalizedStringResource = "问 Clio"
    static let description = IntentDescription("打开 Clio，停在最近那段絮语的输入框。可以先带一句话进去，不会自动发出去。")
    static let openAppWhenRun = true

    @Parameter(title: "想说的话", requestValueDialog: "想跟旅伴说什么？")
    var words: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutDoor.knock(.ask(words ?? ""))
        return .result()
    }
}

struct DictateToClioIntent: AppIntent {
    static let title: LocalizedStringResource = "对 Clio 说话"
    static let description = IntentDescription("打开 Clio，在最近那段絮语里开始听写。说完你自己点发送。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutDoor.knock(.dictate)
        return .result()
    }
}

struct FreshLeafIntent: AppIntent {
    static let title: LocalizedStringResource = "Clio 另起一叶"
    static let description = IntentDescription("和最近的旅伴从头聊起：眼下的絮语收起来，停在空白的输入框。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutDoor.knock(.fresh)
        return .result()
    }
}

/// What Siri knows without setup, and what shows in the Shortcuts app.
struct ClioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskClioIntent(),
            phrases: ["问 \(.applicationName)", "跟 \(.applicationName) 说", "Ask \(.applicationName)"],
            shortTitle: "问 Clio",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: DictateToClioIntent(),
            phrases: ["对 \(.applicationName) 说话", "用 \(.applicationName) 语音输入", "Dictate to \(.applicationName)"],
            shortTitle: "语音输入",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: FreshLeafIntent(),
            phrases: ["\(.applicationName) 新对话", "在 \(.applicationName) 里另起一叶", "New chat in \(.applicationName)"],
            shortTitle: "另起一叶",
            systemImageName: "square.and.pencil"
        )
    }
}
