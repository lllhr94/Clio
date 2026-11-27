import AgentKit
import Craft
import Foundation
import LocalAuthentication
import SwiftUI

/// 信匣: passwords and keys the user keeps. The words a companion may see sit in a list; the secrets sit in the Keychain.
@MainActor
final class Secrets: ObservableObject {
    static let shared = Secrets()

    struct Item: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case ssh, web, key, note
            var title: String {
                switch self {
                case .ssh: "SSH 主机"
                case .web: "网站账号"
                case .key: "密钥 / 令牌"
                case .note: "别的"
                }
            }
            var symbol: String {
                switch self {
                case .ssh: "server.rack"
                case .web: "globe"
                case .key: "key"
                case .note: "lock.doc"
                }
            }
        }

        var id = String(UUID().uuidString.prefix(8)).lowercased()
        var title: String
        var kind: Kind = .web
        /// A host, a site, or where it is used.
        var site: String = ""
        var user: String = ""
        var note: String = ""
        var at: Double = Date().timeIntervalSince1970 * 1000
    }

    @Published private(set) var items: [Item] = []

    init() {
        items = Disk.load([Item].self, "secrets.json") ?? []
    }

    func save(_ item: Item, secret: String?) {
        var item = item
        item.at = Date().timeIntervalSince1970 * 1000
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.insert(item, at: 0) }
        if let secret, !secret.isEmpty { Vault.save(secret, as: "secret.\(item.id)") }
        Disk.save(items, "secrets.json")
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        Vault.remove("secret.\(item.id)")
        Disk.save(items, "secrets.json")
    }

    func item(_ id: String) -> Item? {
        let wanted = id.trimmingCharacters(in: .whitespaces).lowercased()
        return items.first { $0.id == wanted } ?? items.first { $0.title.lowercased() == wanted }
    }

    nonisolated static func secret(_ id: String) -> String? {
        guard let value = Vault.load(String.self, key: "secret.\(id)"), !value.isEmpty else { return nil }
        return value
    }

    /// Face ID, Touch ID or the passcode, before showing or copying a secret.
    static func unlock(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// What a companion may see of an item: never the secret.
    nonisolated static func describe(_ item: Item) -> String {
        var parts = ["[\(item.id)] \(item.title)（\(item.kind.title)）"]
        if !item.site.isEmpty { parts.append("地址 \(item.site)") }
        if !item.user.isEmpty { parts.append("用户名 \(item.user)") }
        if !item.note.isEmpty { parts.append("备注 \(item.note)") }
        parts.append(secret(item.id) == nil ? "（没存密码）" : "（存有密码）")
        return parts.joined(separator: " · ")
    }
}

// MARK: Asking the user to fill something in

/// A slip a companion hands the user to fill in. Answers come back through the continuation.
@MainActor
final class Asker: ObservableObject {
    static let shared = Asker()

    struct Field: Identifiable, Hashable, Sendable {
        var id: String { key }
        var key: String
        var label: String
        var secret = false
        var placeholder = ""
        var value = ""
        /// A picker instead of a text field.
        var choices: [String] = []
        /// Structured v2 question metadata; nil `askKind` infers `.single` when options exist, else `.text`.
        var askKind: AskFieldKind? = nil
        var options: [AskOption] = []
        var allowCustom = false
        var minSelections: Int? = nil
        var maxSelections: Int? = nil
        var defaultSelections: [String] = []
        var required = false
        var optionalBadge = false

        var effectiveKind: AskFieldKind {
            if secret { return .text }
            if let askKind { return askKind }
            return effectiveOptions.isEmpty ? .text : .single
        }

        var effectiveOptions: [AskOption] {
            if secret { return [] }
            if !options.isEmpty { return options }
            return choices.map { AskOption(value: $0) }
        }

        var askQuestion: AskQuestion {
            let effectiveRequired: Bool
            if optionalBadge {
                effectiveRequired = false
            } else if askKind == nil && !effectiveOptions.isEmpty {
                effectiveRequired = true
            } else {
                effectiveRequired = required
            }
            return AskQuestion(
                key: key,
                label: label,
                kind: effectiveKind,
                options: effectiveOptions,
                allowCustom: secret ? false : allowCustom,
                minSelections: secret ? nil : minSelections,
                maxSelections: secret ? nil : maxSelections,
                placeholder: placeholder,
                defaultValue: secret ? "" : value,
                defaultSelections: secret ? [] : defaultSelections,
                required: effectiveRequired,
                explicitlyOptional: optionalBadge,
                secret: secret
            )
        }
    }

    struct Form: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var reason: String
        var from: String
        var fields: [Field]
        /// What the form is for, so a secret saved from it gets a sensible kind.
        var kind: Secrets.Item.Kind = .note
        var site = ""
        /// The conversation that asked, so its page shows it and stopping it puts it away; nil for the app's own
        /// questions (a download, say).
        var chat: String?
        /// Forced Vault routing: any prompt asking for a secret or credential MUST stay off inline chat.
        var requiresVault = false

        /// A short slip with nothing secret is answered right in the conversation; the rest get the full sheet.
        var inline: Bool { !requiresVault && kind == .note && fields.count <= 3 && !fields.contains(where: \.secret) }
    }

    /// Filled values by key; nil when the user put the slip away.
    typealias Answer = [String: String]?

    /// The slip on show; others wait their turn behind it.
    @Published private(set) var current: Form?
    /// When a space-constrained `InlineAsk` requests the full detail sheet, tracks its `form.id`
    /// so dismissing the sheet returns to the inline form without losing `form.id` or drafts.
    @Published private(set) var expandedDetailFormID: UUID?
    /// Forms currently rendered inline inside a conversation page, tracked by `form.id`.
    var inlineSeen: Set<UUID> = []
    /// Every slip still waiting for the user, in the order asked. Two companions asking at once each get their own
    /// answer: a new slip no longer pushes out the one before (the review, #21).
    private var line: [(form: Form, continuation: CheckedContinuation<Answer, Never>)] = []

    func requestDetailSheet(_ id: UUID) {
        guard current?.id == id else { return }
        expandedDetailFormID = id
    }

    func clearDetailSheetRequest(_ id: UUID) {
        if expandedDetailFormID == id {
            expandedDetailFormID = nil
        }
    }

    func ask(_ form: Form) async -> Answer {
        await withCheckedContinuation { continuation in
            line.append((form, continuation))
            if current == nil { showNext() }
        }
    }

    private func showNext() {
        current = line.first?.form
        if current != nil { Haptics.tick(0.8) }
    }

    /// Answers one slip by its id; an answer from a slip that is no longer waiting goes nowhere.
    func answer(_ values: Answer, to id: UUID) {
        inlineSeen.remove(id)
        if expandedDetailFormID == id { expandedDetailFormID = nil }
        guard let index = line.firstIndex(where: { $0.form.id == id }) else { return }
        let item = line.remove(at: index)
        if current?.id == id { showNext() }
        item.continuation.resume(returning: values)
    }

    func cancel(_ id: UUID) { answer(nil, to: id) }

    /// Puts away the slips one conversation asked, and only those.
    func cancel(chat: String) {
        for id in line.filter({ $0.form.chat == chat }).map(\.form.id) { cancel(id) }
    }
}

extension Asker.Field {
    init(question: AskQuestion) {
        self.init(
            key: question.key,
            label: question.label,
            secret: question.secret,
            placeholder: question.placeholder,
            value: question.secret ? "" : question.defaultValue,
            choices: question.secret ? [] : question.options.map(\.value),
            askKind: question.secret ? .text : question.kind,
            options: question.secret ? [] : question.options,
            allowCustom: question.secret ? false : question.allowCustom,
            minSelections: question.secret ? nil : question.minSelections,
            maxSelections: question.secret ? nil : question.maxSelections,
            defaultSelections: question.secret ? [] : question.defaultSelections,
            required: question.required,
            optionalBadge: question.explicitlyOptional && !question.secret
        )
    }
}

// MARK: Tools

enum SecretTools {
    static func all(botName: String, chat: String) -> [AgentTool] {
        [
            DeskTool(name: "ask_user", description: """
            递一张小笺请用户选择或填写信息：支持单选（single）、多选（multi）、自由输入（text）以及多字段表单（fields）。用户填好你才拿到结果。
            既可以直接传单个问题（question + options/choices + type/allowCustom），也可以传多个字段（fields 数组，每项含 key、label、type、options、choices、allowCustom、minSelections、maxSelections、placeholder、value、required、secret）。
            options 为结构化对象数组 {label, value?, description?, recommended?}；纯字符串选项列表请传 choices: ["选项A", "选项B"]。设 allowCustom: true 时允许用户选「其他 / 自己写」。
            机密的项（如密码、密钥、令牌、验证码等）请标 secret: true，它会强制走信匣保存，你只拿到一个信匣编号，永远看不到原文。不要在聊天里让用户直接打出密码。
            """, parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "笺的标题，比如「选择输出方式」或「登录信息」"],
                    "question": ["type": "string", "description": "单问题时的提问文案（与 fields 二选一）"],
                    "prompt": ["type": "string", "description": "question 的别名"],
                    "reason": ["type": "string", "description": "一句话说明为什么要选或要填"],
                    "site": ["type": "string", "description": "这些信息用在哪（网址或主机），可不填"],
                    "type": ["type": "string", "enum": ["single", "multi", "text"], "description": "单问题时的题型"],
                    "options": ["type": "array", "description": "结构化可选项数组，每项为 {label, value?, description?, recommended?}", "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string", "description": "展示给用户的选项文案"],
                            "value": ["type": "string", "description": "回传给你的值，省略时与 label 相同"],
                            "description": ["type": "string", "description": "可选的补充说明"],
                            "recommended": ["type": "boolean", "description": "是否标为推荐"],
                        ],
                    ]],
                    "choices": ["type": "array", "items": ["type": "string"], "description": "纯字符串可选项列表，例如 [\"选项A\", \"选项B\"]"],
                    "allowCustom": ["type": "boolean", "description": "是否允许用户输入自定义内容，默认 false"],
                    "minSelections": ["type": "integer", "description": "多选最少选几项"],
                    "maxSelections": ["type": "integer", "description": "多选最多选几项"],
                    "placeholder": ["type": "string"],
                    "value": ["type": "string"],
                    "required": ["type": "boolean"],
                    "secret": ["type": "boolean"],
                    "fields": ["type": "array", "items": ["type": "object", "properties": [
                        "key": ["type": "string"], "label": ["type": "string"], "secret": ["type": "boolean"],
                        "type": ["type": "string", "enum": ["single", "multi", "text"]],
                        "options": ["type": "array", "description": "结构化可选项数组，每项为 {label, value?, description?, recommended?}", "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string", "description": "展示给用户的选项文案"],
                                "value": ["type": "string", "description": "回传给你的值，省略时与 label 相同"],
                                "description": ["type": "string", "description": "可选的补充说明"],
                                "recommended": ["type": "boolean", "description": "是否标为推荐"],
                            ],
                        ]],
                        "choices": ["type": "array", "items": ["type": "string"], "description": "纯字符串可选项列表"],
                        "allowCustom": ["type": "boolean"],
                        "minSelections": ["type": "integer"],
                        "maxSelections": ["type": "integer"],
                        "placeholder": ["type": "string"], "value": ["type": "string"],
                        "required": ["type": "boolean"],
                    ], "required": ["key", "label"]]],
                ],
            ], label: { args in
                let heading = (args["title"]?.string ?? args["question"]?.string ?? args["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Words.t("递笺：\(heading)")
            }) { arguments in
                let prompt: AskPrompt
                switch AskUserRules.parse(arguments) {
                case .failure(let error):
                    return ToolOutput(error.userMessage, isError: true)
                case .success(let parsed):
                    prompt = parsed
                }
                let fields = prompt.questions.map { Asker.Field(question: $0) }
                let form = Asker.Form(
                    title: prompt.title,
                    reason: prompt.reason,
                    from: botName,
                    fields: fields,
                    kind: prompt.site.hasPrefix("http") ? .web : .note,
                    site: prompt.site,
                    chat: chat,
                    requiresVault: prompt.requiresVault
                )
                guard !prompt.requiresVault || !form.inline else {
                    return ToolOutput("安全路由校验未通过。", isError: true)
                }
                guard let values = await Asker.shared.ask(form) else {
                    return ToolOutput("用户把笺收起来了，没有填。", isError: true)
                }
                switch AskUserRules.formatResult(prompt: prompt, rawValues: values) {
                case .failure(let error):
                    return ToolOutput(error.userMessage, isError: true)
                case .success(let formatted):
                    return ToolOutput(formatted)
                }
            },
            DeskTool(name: "vault_list", description: "看信匣里存了哪些账号和密钥：编号、名字、地址、用户名。看不到密码。", parameters: ["type": "object", "properties": [:]], label: { _ in Words.t("信匣：翻看") }) { _ in
                let items = await Secrets.shared.items
                guard !items.isEmpty else { return ToolOutput("信匣是空的。") }
                return ToolOutput(items.map(Secrets.describe).joined(separator: "\n"))
            },
            DeskTool(name: "ssh_add_host", description: "请用户添一台 SSH 主机（远山）：递一张笺，地址、端口、用户名先替用户填上，密码由用户自己填（会存进钥匙串和信匣，你看不到）。存好后就能用 ssh_run。", parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "给主机起的名字"],
                    "address": ["type": "string"],
                    "port": ["type": "number"],
                    "user": ["type": "string"],
                ],
            ], label: { Words.t("远山：添主机 \($0["address"]?.string ?? "")") }) { arguments in
                let form = Asker.Form(
                    title: "添一台主机",
                    reason: Words.t("存好后，旅伴就能用 SSH 在这台主机上替你跑命令。密码只存在这台手机里。"),
                    from: botName,
                    fields: [
                        Asker.Field(key: "name", label: "称呼", placeholder: "比如：香港 VPS", value: arguments["name"]?.string ?? ""),
                        Asker.Field(key: "address", label: "地址", placeholder: "域名或 IP", value: arguments["address"]?.string ?? ""),
                        Asker.Field(key: "port", label: "端口", placeholder: "22", value: Whole.int(arguments["port"]).map(String.init) ?? "22"),
                        Asker.Field(key: "user", label: "用户名", placeholder: "root", value: arguments["user"]?.string ?? "root"),
                        Asker.Field(key: "auth", label: "登录方式", value: "密码", choices: ["密码", "钥匙"]),
                        Asker.Field(key: "password", label: "密码（用钥匙就留空）", secret: true),
                    ],
                    kind: .ssh,
                    site: arguments["address"]?.string ?? "",
                    chat: chat
                )
                guard let values = await Asker.shared.ask(form) else { return ToolOutput("用户没有添主机。", isError: true) }
                let address = (values["address"] ?? "").trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { return ToolOutput("地址是空的。", isError: true) }
                let useKey = values["auth"] == "钥匙"
                let trimmedName = (values["name"] ?? "").trimmingCharacters(in: .whitespaces)
                let trimmedUser = (values["user"] ?? "").trimmingCharacters(in: .whitespaces)
                var host = Hills.Host(name: trimmedName.isEmpty ? address : trimmedName, address: address, user: trimmedUser.isEmpty ? "root" : trimmedUser)
                let parsedPort = Int((values["port"] ?? "").trimmingCharacters(in: .whitespaces)) ?? 22
                host.port = (1...65535).contains(parsedPort) ? parsedPort : 22
                host.useKey = useKey
                var password: String?
                if let saved = values["password"], saved.hasPrefix("secret:") { password = Secrets.secret(String(saved.dropFirst(7))) }
                let finalHost = host
                let finalPassword = password
                await MainActor.run { Hills.shared.save(finalHost, password: finalPassword) }
                if !useKey && password == nil { return ToolOutput("主机「\(host.name)」存好了，但没填密码，连不上。可以请用户在「远山」里补上。", isError: true) }
                return ToolOutput("主机「\(host.name)」（\(host.user)@\(host.address):\(host.port)）存好了\(useKey ? "，用钥匙登录——要确认公钥已加到服务器上" : "")。现在可以用 ssh_run，host 填「\(host.name)」。")
            },
            DeskTool(name: "browser_fill_secret", description: "用信匣里的一条，把密码（或用户名）填进远游页面上编号为 ref 的输入框。你看不到填了什么。先用 vault_list 找编号。", parameters: [
                "type": "object",
                "properties": [
                    "ref": ["type": "number"],
                    "id": ["type": "string", "description": "信匣编号"],
                    "field": ["type": "string", "enum": ["password", "user"], "description": "填密码还是用户名，默认密码"],
                    "submit": ["type": "boolean"],
                ],
                "required": ["ref", "id"],
            ], label: { Words.t("远游：从信匣填入 [\(Whole.int($0["ref"]) ?? 0)]") }, approval: { arguments in
                ApprovalAsk(title: Words.t("从信匣取出来填进网页"), reason: Words.t("信匣编号 ") + "\(arguments["id"]?.string ?? "")，填\(arguments["field"]?.string == "user" ? "用户名" : "密码")", forced: true)
            }) { arguments in
                let id = arguments["id"]?.string ?? ""
                guard let item = await Secrets.shared.item(id) else { return ToolOutput("信匣里没有编号 \(id)。", isError: true) }
                let wantsUser = arguments["field"]?.string == "user"
                guard let value = wantsUser ? (item.user.isEmpty ? nil : item.user) : Secrets.secret(item.id) else { return ToolOutput("这一条没存\(wantsUser ? "用户名" : "密码")。", isError: true) }
                guard let ref = Whole.int(arguments["ref"]) else { return ToolOutput("ref 要是 browser_read 给的编号。", isError: true) }
                let submit = arguments["submit"]?.bool ?? false
                guard let browser = await RoamTools.browser else { return ToolOutput("远游还没开。", isError: true) }
                // Only on the site the entry is for, and a password only into a password box: otherwise a page (or a
                // model steered by one) could have a kept password typed where it can read it back.
                let done = try await browser.fillSecret(ref, text: value, submit: submit, for: chat,
                                                        site: item.site, password: !wantsUser, entry: item.title)
                return ToolOutput(done)
            },
        ]
    }
}
