import AgentKit
import AppIntents
import Craft
import SwiftUI

/// What Siri or a shortcut asked for. Each one only opens Clio at the composer: nothing is sent on its own.
enum ShortcutAsk: Equatable {
    /// Open the newest conversation with these words in the composer (maybe none).
    case ask(String)
    /// Open the newest conversation and start listening.
    case dictate
    /// Turn a new leaf with the newest companion and wait at the composer.
    case fresh
    /// Files shared to Clio from another app, already copied safely into 书案/收件 while security scope was active.
    case importedFiles(paths: [String], failed: [String])
}

/// Hands a shortcut's request to the screens. Kept until taken, because a cold start draws the desk after the intent has run.
@MainActor
enum ShortcutDoor {
    /// Waiting for the desk to pick a conversation.
    static var pending: ShortcutAsk?
    /// Waiting for the desk to open a specific chat (`clio://chat/...`) on cold start.
    static var pendingChat: String?
    /// Waiting for the desk to open a specific settings destination (`clio://settings/...`) on cold start.
    static var pendingSettings: String?
    /// Waiting for that conversation's page, by chat key.
    static var forChat: [String: ShortcutAsk] = [:]

    static func knock(_ ask: ShortcutAsk) {
        if case .importedFiles(let newPaths, let newFailed) = ask,
           case .importedFiles(let oldPaths, let oldFailed) = pending {
            pending = .importedFiles(paths: oldPaths + newPaths, failed: oldFailed + newFailed)
        } else {
            pending = ask
        }
        NotificationCenter.default.post(name: .clioShortcut, object: nil)
    }

    static func take(for key: String) -> ShortcutAsk? { forChat.removeValue(forKey: key) }
}

extension Notification.Name {
    /// Siri or a shortcut asked for something; see `ShortcutDoor`.
    static let clioShortcut = Notification.Name("clio.shortcut")
    /// The desk has picked the conversation; its page takes the request.
    static let clioShortcutReady = Notification.Name("clio.shortcutReady")
    /// Deep link asked to open a settings page.
    static let clioSettingsRoute = Notification.Name("clio.settingsRoute")
}

struct AskClioIntent: AppIntent {
    static let title: LocalizedStringResource = "问 Clio"
    static let description = IntentDescription("打开 Clio，停在最近那段对话的输入框。可以先带一句话进去，不会自动发出去。")
    static let openAppWhenRun = true

    @Parameter(title: "想说的话", requestValueDialog: "想跟 Clio 说什么？")
    var words: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutDoor.knock(.ask(words ?? ""))
        return .result()
    }
}

struct DictateToClioIntent: AppIntent {
    static let title: LocalizedStringResource = "对 Clio 说话"
    static let description = IntentDescription("打开 Clio，在最近那段对话里开始听写。说完你自己点发送。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutDoor.knock(.dictate)
        return .result()
    }
}

struct FreshLeafIntent: AppIntent {
    static let title: LocalizedStringResource = "Clio 新对话"
    static let description = IntentDescription("和最近的助手从头聊起：收起当前对话，停在空白输入框。")
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
    static let description = IntentDescription("不打开 Clio，用默认模型回答一个问题，把答案交给快捷指令的下一步。不查网页、不动手做事，也不记进对话。")
    static let openAppWhenRun = false

    @Parameter(title: "问题", requestValueDialog: "想问什么？")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if UserDefaults.standard.bool(forKey: "lock.faceid") {
            let unlocked = await MainActor.run { AppLock.isCurrentlyUnlocked }
            guard unlocked else {
                throw TeamError(message: "Clio 已开启面容锁，请先打开 Clio 解锁后再试。")
            }
        }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { throw TeamError(message: "没听到问题。") }
        let settings = Disk.load(TeamSettings.self, "settings.json") ?? TeamSettings()
        guard let ref = settings.defaultModel, let slash = ref.firstIndex(of: "/"),
              let endpoint = settings.endpoints.first(where: { $0.id == ref[..<slash] }) else {
            throw TeamError(message: "Clio 里还没有可用的模型，先打开 Clio 接一家模型服务。")
        }
        let model = String(ref[ref.index(after: slash)...])
        guard let key = EndpointKeyCoordinator.resolveBoundKey(
            endpointID: endpoint.id,
            baseURL: endpoint.baseURL,
            readKey: { Vault.load(String.self, key: $0) },
            readBoundOrigin: TeamModel.boundKeyOrigin(for:)
        ) else {
            throw TeamError(message: "拿不到 \(endpoint.name) 的密钥，解锁手机后再试一次。")
        }
        let agent = Agent(provider: endpoint.provider(key: key), model: model,
                          system: "你在快捷指令里回答用户的一个问题。中文，先说结论，几句话说完，不用 Markdown 格式；不知道最新情况就直说。现在是 \(Date().formatted(date: .complete, time: .shortened))。")
        let answer = try await agent.ask(asked)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct ShareToClioIntent: AppIntent {
    static let title: LocalizedStringResource = "发给 Clio"
    static let description = IntentDescription("把文字、网页链接或从别的 App 共享的内容带进 Clio 输入框，不会自动发出去。可在快捷指令里开启「在共享表单中显示」。")
    static let openAppWhenRun = true

    @Parameter(title: "内容或文字")
    var text: String?

    @Parameter(title: "网页链接")
    var url: URL?

    @Parameter(title: "附言（可选）")
    var prompt: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let composed = ShortcutText.compose(text: text, url: url?.absoluteString, title: nil, prompt: prompt)
        ShortcutDoor.knock(.ask(composed))
        return .result()
    }
}

enum ShortcutText {
    /// Formats shared text, URL, title, and optional prompt into clean composer input.
    static func compose(text: String?, url: String?, title: String?, prompt: String?) -> String {
        let cleanPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var parts: [String] = []
        if !cleanPrompt.isEmpty { parts.append(cleanPrompt) }
        if !cleanText.isEmpty { parts.append(cleanText) }
        if !cleanURL.isEmpty {
            if parts.isEmpty {
                if !cleanTitle.isEmpty {
                    parts.append("请帮我看看这篇内容（\(cleanTitle)）：\n\(cleanURL)")
                } else {
                    parts.append("请帮我看看这个链接：\n\(cleanURL)")
                }
            } else if !cleanText.contains(cleanURL) {
                parts.append(cleanURL)
            }
        } else if parts.isEmpty, !cleanTitle.isEmpty {
            parts.append(cleanTitle)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Parses query items from `clio://ask?...` or `clio://share?...`.
    static func fromURL(_ incoming: URL) -> String {
        guard let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return ""
        }
        func value(_ names: [String]) -> String? {
            for name in names {
                if let hit = items.first(where: { $0.name.lowercased() == name })?.value,
                   !hit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return hit
                }
            }
            return nil
        }
        let text = value(["text", "q", "words", "body", "content"])
        let link = value(["url", "link"])
        let title = value(["title"])
        let prompt = value(["prompt", "instruction"])
        return compose(text: text, url: link, title: title, prompt: prompt)
    }
}

/// What Siri or a shortcut knows without setup, and what shows in the Shortcuts app.
struct ClioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskClioIntent(),
            phrases: ["问 \(.applicationName)", "跟 \(.applicationName) 说", "Ask \(.applicationName)"],
            shortTitle: "问 Clio",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: ShareToClioIntent(),
            phrases: ["发给 \(.applicationName)", "分享给 \(.applicationName)", "Send to \(.applicationName)"],
            shortTitle: "发给 Clio",
            systemImageName: "square.and.arrow.up"
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
            shortTitle: "新对话",
            systemImageName: "square.and.pencil"
        )
    }
}
