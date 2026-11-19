import AgentKit
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
    /// Files shared to Clio from another app (共享 → Clio): they go into 书案/收件 and wait in the composer.
    case files([URL])
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

/// Asks the default model one question and hands back the answer, without opening Clio: for chaining in Shortcuts
/// and for Siri reading it out. No tools and nothing done on the person's behalf, so nothing needs approving;
/// not kept in any conversation.
struct QuickAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "Clio 直接回答"
    static let description = IntentDescription("不打开 Clio，用默认模型回答一个问题，把答案交给快捷指令的下一步。不查网页、不动手做事，也不记进絮语。")
    static let openAppWhenRun = false

    @Parameter(title: "问题", requestValueDialog: "想问什么？")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { throw TeamError(message: "没听到问题。") }
        let settings = Disk.load(TeamSettings.self, "settings.json") ?? TeamSettings()
        guard let ref = settings.defaultModel, let slash = ref.firstIndex(of: "/"),
              let endpoint = settings.endpoints.first(where: { $0.id == ref[..<slash] }) else {
            throw TeamError(message: "Clio 里还没有可用的模型，先打开 Clio 接一家模型服务。")
        }
        let model = String(ref[ref.index(after: slash)...])
        guard let key = Vault.load(String.self, key: "key-\(endpoint.id)"), !key.isEmpty else {
            throw TeamError(message: "拿不到 \(endpoint.name) 的密钥，解锁手机后再试一次。")
        }
        let agent = Agent(provider: endpoint.provider(key: key), model: model,
                          system: "你在快捷指令里回答用户的一个问题。中文，先说结论，几句话说完，不用 Markdown 格式；不知道最新情况就直说。现在是 \(When.show(Date()))。")
        let answer = try await agent.ask(asked)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
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
            intent: QuickAnswerIntent(),
            phrases: ["让 \(.applicationName) 直接回答", "\(.applicationName) 回答一下", "Quick answer from \(.applicationName)"],
            shortTitle: "直接回答",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: FreshLeafIntent(),
            phrases: ["\(.applicationName) 新对话", "在 \(.applicationName) 里另起一叶", "New chat in \(.applicationName)"],
            shortTitle: "另起一叶",
            systemImageName: "square.and.pencil"
        )
    }
}
