import AgentKit
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

        /// A short slip with nothing secret is answered right in the conversation; the rest get the full sheet.
        var inline: Bool { kind == .note && fields.count <= 3 && !fields.contains(where: \.secret) }
    }

    /// Filled values by key; nil when the user put the slip away.
    typealias Answer = [String: String]?

    /// The slip on show; others wait their turn behind it.
    @Published private(set) var current: Form?
    /// Forms currently rendered inline inside a conversation page, tracked by `form.id`.
    var inlineSeen: Set<UUID> = []
    /// Every slip still waiting for the user, in the order asked. Two companions asking at once each get their own
    /// answer: a new slip no longer pushes out the one before (the review, #21).
    private var line: [(form: Form, continuation: CheckedContinuation<Answer, Never>)] = []

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

// MARK: Tools

enum SecretTools {
    static func all(botName: String, chat: String) -> [AgentTool] {
        [
            DeskTool(name: "ask_user", description: """
            递一张小笺请用户填写信息：比如地址、账号、日期、选项。用户填好你才拿到结果。
            fields 里每一项：key（结果里的名字）、label（给用户看的名字）、secret（是否机密，如密码、令牌）、placeholder、value（预先填好的）、choices（可选项列表）。
            机密的项不会交给你：它会存进信匣，你只拿到一个信匣编号，之后可用 browser_fill_secret 或 ssh 相关工具使用它。不要在聊天里让用户直接打出密码。
            """, parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "笺的标题，比如「登录信息」"],
                    "reason": ["type": "string", "description": "一句话说明为什么要填"],
                    "site": ["type": "string", "description": "这些信息用在哪（网址或主机），可不填"],
                    "fields": ["type": "array", "items": ["type": "object", "properties": [
                        "key": ["type": "string"], "label": ["type": "string"], "secret": ["type": "boolean"],
                        "placeholder": ["type": "string"], "value": ["type": "string"],
                        "choices": ["type": "array", "items": ["type": "string"]],
                    ], "required": ["key", "label"]]],
                ],
                "required": ["title", "fields"],
            ], label: { Words.t("递笺：\($0["title"]?.string ?? "")") }) { arguments in
                var seenKeys: Set<String> = []
                let fields: [Asker.Field] = (arguments["fields"]?.array ?? []).compactMap { item in
                    guard let rawKey = item["key"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !rawKey.isEmpty,
                          seenKeys.insert(rawKey).inserted else { return nil }
                    let label = item["label"]?.string ?? rawKey
                    // A field that asks for a password, a code or a card number is kept in 信匣 whatever the model said:
                    // otherwise its answer would go back to the model as plain text.
                    let words = (rawKey + " " + label + " " + (item["placeholder"]?.string ?? "")).lowercased()
                    let sensitive = ["密码", "口令", "password", "passwd", "验证码", "otp", "pin码", "pin code", "卡号", "安全码", "cvv", "token", "令牌", "密钥", "api key", "apikey", "secret"].contains { words.contains($0) }
                    return Asker.Field(key: rawKey, label: label, secret: (item["secret"]?.bool ?? false) || sensitive,
                                       placeholder: item["placeholder"]?.string ?? "", value: item["value"]?.string ?? "",
                                       choices: (item["choices"]?.array ?? []).compactMap(\.string))
                }
                guard !fields.isEmpty else { return ToolOutput("fields 是空的。", isError: true) }
                let site = arguments["site"]?.string ?? ""
                let form = Asker.Form(title: arguments["title"]?.string ?? "请填一下", reason: arguments["reason"]?.string ?? "", from: botName,
                                      fields: fields, kind: site.hasPrefix("http") ? .web : .note, site: site, chat: chat)
                guard let values = await Asker.shared.ask(form) else { return ToolOutput("用户把笺收起来了，没有填。", isError: true) }
                let lines = fields.map { field -> String in
                    let value = values[field.key] ?? ""
                    if field.secret {
                        if value.hasPrefix("secret:") { return "\(field.key)：已存进信匣，编号 \(value.dropFirst(7))（你看不到内容）" }
                        return value.isEmpty ? "\(field.key)：（没填）" : "\(field.key)：（已填）"
                    }
                    return "\(field.key)：\(value)"
                }
                return ToolOutput("用户填好了：\n" + lines.joined(separator: "\n"))
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
