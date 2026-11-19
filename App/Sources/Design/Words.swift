import Foundation

/// 叫法: the poetic names (絮语、候印、调弦…) or the plain ones (对话、批准、设置…), as the user picks in 纸墨.
/// Words shown on screen go through `Words.t`; reading `Theme.shared.plain` makes the views redraw when it changes.
enum Words {
    /// Poetic → plain, longest first so 纸墨与絮语 goes before 絮语.
    static let table: [(String, String)] = [
        ("纸墨与絮语", "外观与对话"),
        ("絮语页", "对话记录"),
        ("另起一叶", "新对话"),
        ("收起的一叶", "旧对话"),
        ("候印", "待批准"),
        ("落印", "批准"),
        ("调弦", "设置"),
        ("应许", "权限"),
        ("拾遗", "记忆"),
        ("书案", "文件"),
        ("斗室", "终端"),
        ("远山", "远程主机"),
        ("远游", "浏览器"),
        ("信匣", "密码箱"),
        ("养护", "诊断"),
        ("雅集", "群聊"),
        ("名帖", "资料卡"),
        ("案头", "首页"),
        ("本事", "能力"),
        ("潮水", "每日拾物"),
        ("旅伴", "助手"),
        ("絮语", "对话"),
        ("一叶", "一页"),
    ]

    static var plain: Bool { Theme.shared.plain }

    /// The words as the user wants them named.
    static func t(_ text: String) -> String {
        guard plain else { return text }
        var out = text
        for (poetic, everyday) in table where out.contains(poetic) {
            out = out.replacingOccurrences(of: poetic, with: everyday)
        }
        return out
    }

    /// Back from a plain name to the poetic one, for code that looks names up (icons by label).
    static func poetic(_ word: String) -> String {
        table.first { $0.1 == word }?.0 ?? word
    }

    /// For the model: which names the user sees, so it uses the same ones.
    static var promptLine: String? {
        guard plain else { return nil }
        let pairs = table.filter { !["一叶", "收起的一叶", "另起一叶"].contains($0.0) }.map { "\($0.0)→\($0.1)" }.joined(separator: "、")
        return "用户的界面用普通叫法，跟用户说话时也这样叫（设定里的旧名对应：\(pairs)）。"
    }
}
