import Foundation

/// What a companion is doing, said plainly, wherever it shows: the chat's live line, the desk, the header.
enum Live {
    /// Tool labels' first word, in the glossary's terms.
    static func word(_ label: String) -> String {
        switch label {
        case "搜索": "寻访"
        case "读网页": "远游"
        case "记住": "拾遗"
        case "忘掉": "删去拾遗"
        case "看日历", "看提醒事项": "翻看"
        default: label
        }
    }

    /// 「收到了，团子正在想」「正在寻访：重庆天气」… nil when idle.
    static func words(_ doing: String?, name: String, waiting: Bool = false) -> String? {
        if waiting { return "等你落印：输入框上方有一张笺，点开看看它想做什么" }
        guard let doing else { return nil }
        switch doing {
        case "正在想": return "收到了，\(name)正在想"
        case "正在回复": return "\(name)正在写"
        case "正在压缩前文": return "聊得有点长了，先把前文压成一份提要"
        case "等你批准": return "等你落印"
        default:
            if doing.hasSuffix("在想") { return "收到了，\(doing)" }
            let parts = doing.split(separator: "：", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return doing }
            return "正在\(word(parts[0]))：\(parts[1])"
        }
    }

    /// Shorter, for a line on the desk.
    static func brief(_ doing: String?, waiting: Bool) -> String? {
        if waiting { return "等你落印" }
        guard let doing else { return nil }
        switch doing {
        case "正在想": return "正在想…"
        case "正在回复": return "正在写…"
        case "正在压缩前文": return "正在压缩前文…"
        default:
            let parts = doing.split(separator: "：", maxSplits: 1).map(String.init)
            return parts.count == 2 ? "正在\(word(parts[0]))…" : doing
        }
    }
}
