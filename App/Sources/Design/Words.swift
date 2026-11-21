import Foundation

/// 称谓: every name and prompt on screen comes from one of two dictionaries, 日常 (`zh-CN.daily.json`) or
/// 书卷 (`zh-CN.literary.json`), both with exactly the same keys. Switching 称谓 swaps the dictionary, so the whole
/// app changes together. Reading `Theme.shared.plain` makes the views redraw when it changes.
enum L {
    private static func load(_ name: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var flat: [String: String] = [:]
        func walk(_ node: [String: Any], _ prefix: String) {
            for (key, value) in node {
                if let inner = value as? [String: Any] { walk(inner, prefix + key + ".") }
                else if let text = value as? String { flat[prefix + key] = text }
            }
        }
        walk(tree, "")
        return flat
    }

    static let daily = load("zh-CN.daily")
    static let literary = load("zh-CN.literary")

    /// Settings search uses both dictionaries. Start loading the other vocabulary after launch,
    /// instead of making the first click into Settings do it.
    static func prepare() {
        Task.detached(priority: .utility) {
            _ = daily
            _ = literary
        }
    }

    /// True in 日常.
    static var plain: Bool { Theme.shared.plain }

    /// The words for `key`, in the 称谓 the user picked. A key missing from a dictionary shows the other one's words.
    static func t(_ key: String) -> String {
        (plain ? daily[key] ?? literary[key] : literary[key] ?? daily[key]) ?? key
    }

    static func format(_ key: String, _ values: CVarArg...) -> String {
        String(format: t(key), arguments: values)
    }

    /// 日常旁注: in 书卷 with the side note on, the everyday words for the same key, shown small and gray beside it.
    /// Nothing when both say the same thing.
    static func hint(_ key: String) -> String? {
        guard !plain, Theme.shared.hint, let everyday = daily[key], everyday != literary[key] else { return nil }
        return everyday
    }
}

/// The older way names reach the screen: sentences written with the old 书卷 names (絮语、候印、调弦…).
/// `Words.t` swaps each old name for what it is called now, in the 称谓 the user picked.
enum Words {
    /// Old name → dictionary key. Longest names are matched first, so 纸墨与絮语 goes before 絮语.
    static let names: [(String, String)] = [
        ("纸墨与絮语", "settings.appearanceAndChat"),
        ("案头与小屋", "nav.filesAndTerminal"),
        ("常记在心", "organize.pinMemory"),
        ("收进旧事", "organize.toEarlier"),
        ("收起的一叶", "chat.oldConversation"),
        ("另起一叶", "chat.newConversation"),
        ("落印笺", "approval.approvalSheet"),
        ("絮语页", "chat.conversationHistory"),
        ("纸墨", "settings.appearance"),
        ("晨信", "agent.morningBrief"),
        ("常记", "organize.frequent"),
        ("旧事", "organize.earlier"),
        ("候印", "approval.pending"),
        ("落印", "approval.approve"),
        ("调弦", "nav.settings"),
        ("应许", "settings.permissions"),
        ("拾遗", "nav.memory"),
        ("书案", "nav.files"),
        ("斗室", "nav.terminal"),
        ("远山", "nav.remoteHost"),
        ("远游", "nav.browser"),
        ("信匣", "settings.vault"),
        ("养护", "settings.diagnostics"),
        ("雅集", "nav.groupChat"),
        ("名帖", "organize.profileCard"),
        ("案头", "nav.home"),
        ("本事", "agent.capabilities"),
        ("潮水", "nav.dailyDiscover"),
        ("旅伴", "nav.assistant"),
        ("沉吟", "chat.thinking"),
        ("落笔", "chat.replying"),
        ("闲坐", "chat.idle"),
        ("寻访", "agent.search"),
        ("来信", "agent.reminder"),
        ("所在", "agent.location"),
        ("行迹", "agent.steps"),
        ("递笺", "chat.pleaseFill"),
        ("絮语", "chat.conversation"),
        ("一叶", "chat.page"),
        ("叫法", "settings.tone"),
    ]

    private static let byLength = names.sorted { $0.0.count > $1.0.count }

    static var plain: Bool { Theme.shared.plain }

    /// The text with every old name replaced by its current one, in one pass, so a replacement is never replaced again.
    static func t(_ text: String) -> String {
        let plain = Theme.shared.plain
        // Remembered per text: views call this on every redraw, and a streamed reply redraws many times a second
        // (Open Minis found its own per-redraw word lookups taking a fifth of the main thread while typing).
        let key = (plain ? "1" : "0") + text
        cacheLock.lock()
        let known = cache[key]
        cacheLock.unlock()
        if let known { return known }
        let out = swap(text)
        cacheLock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = out
        cacheLock.unlock()
        return out
    }

    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    private static func swap(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for (old, key) in byLength where rest.hasPrefix(old) {
                out += L.t(key)
                rest = rest.dropFirst(old.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    /// Back from a name on screen to the old one, for code that looks things up by name (icons by label).
    static func poetic(_ word: String) -> String {
        names.first { L.t($0.1) == word || L.daily[$0.1] == word }?.0 ?? word
    }

    /// For the model: the names the user sees, so it uses the same ones.
    static var promptLine: String? {
        let pairs = names.filter { !["一叶", "收起的一叶", "另起一叶", "叫法"].contains($0.0) }
            .compactMap { old, key in L.t(key) == old ? nil : "\(old)→\(L.t(key))" }
        guard !pairs.isEmpty else { return nil }
        return "用户界面上的叫法跟设定里的旧名不一样，跟用户说话时用界面上的叫法（旧名→现在的叫法：\(pairs.joined(separator: "、"))）。"
    }
}
