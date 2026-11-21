import AgentKit
import Foundation

/// One line of a conversation, as the scheduling below needs it.
public protocol Said {
    var id: String { get }
    var role: Message.Role { get }
    var text: String { get }
    /// A line for the user only, never sent to the model.
    var isNote: Bool { get }
}

/// The decisions behind 重来一次、改了重发、压缩前文 and 拆开此叶, apart from the screen and the disk.
public enum Turns {
    static func isUserTurn(_ line: some Said) -> Bool { line.role == .user && !line.isNote }

    /// How long the conversation is in characters, notes left out.
    public static func size<S: Said>(_ lines: [S]) -> Int {
        lines.filter { !$0.isNote }.reduce(0) { $0 + $1.text.count }
    }

    /// The user turns a retry undoes (the last one), or an edit of message `id` undoes (that one and every one after it).
    public static func toUndo<S: Said>(_ lines: [S], from id: String? = nil) -> [String] {
        let users = lines.filter { isUserTurn($0) }
        guard let id else { return users.last.map { [$0.id] } ?? [] }
        guard let index = users.firstIndex(where: { $0.id == id }) else { return [] }
        return users[index...].map(\.id)
    }

    /// A retry keeps everything up to the last thing the user said and drops what came after. Nil when the user has said nothing.
    public static func retried<S: Said>(_ lines: [S]) -> [S]? {
        guard let last = lines.lastIndex(where: { isUserTurn($0) }) else { return nil }
        return Array(lines[...last])
    }

    /// An edit puts `change(message)` where message `id` stood and drops everything after it. Nil when that message is gone.
    public static func edited<S: Said>(_ lines: [S], id: String, change: (S) -> S) -> [S]? {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return nil }
        return Array(lines[..<index]) + [change(lines[index])]
    }

    public enum FoldProblem: Error, Equatable, Sendable {
        /// Not enough said yet to be worth folding.
        case tooShort
        /// No user message to cut before.
        case noBreak

        public var words: String {
            switch self {
            case .tooShort: "这段絮语还不长，用不着压缩。"
            case .noBreak: "找不到合适的地方断开，过一会儿再试。"
            }
        }
    }

    /// Where a compression cuts: the index of the first line kept as it is. The cut falls just before a user message,
    /// so the kept part starts a turn, and leaves at least `keep` real lines (never fewer than 4) after it: the cut
    /// moves earlier to a turn's start, never later past lines the setting says to keep (the review, #18).
    public static func foldCut<S: Said>(_ lines: [S], keep: Int) -> Result<Int, FoldProblem> {
        let real = lines.indices.filter { !lines[$0].isNote }
        let keep = max(4, keep)
        guard real.count > keep + 4 else { return .failure(.tooShort) }
        var cut = real[real.count - keep]
        while cut > 0, !isUserTurn(lines[cut]) { cut -= 1 }
        guard cut > 0, lines[..<cut].contains(where: { !$0.isNote }) else { return .failure(.noBreak) }
        return .success(cut)
    }

    /// Moves a cut earlier, a whole turn at a time, until the part to fold fits in `limit` characters of transcript, so
    /// everything marked as folded was really read by the model writing the digest. A first turn too long on its own
    /// is folded anyway, cut short (`transcript` says so).
    public static func fitCut<S: Said>(_ lines: [S], cut: Int, name: (S) -> String, label: (S) -> String?, limit: Int = 60_000) -> Int {
        var cut = min(cut, lines.count)
        var costs = lines[..<cut].map { line in piece(line, name: name, label: label).map { $0.count + 1 } ?? 0 }
        var total = costs.reduce(0, +)
        while total > limit {
            var earlier = cut - 1
            while earlier > 0, !isUserTurn(lines[earlier]) { earlier -= 1 }
            guard earlier > 0 else { break }
            total -= costs[earlier..<cut].reduce(0, +)
            costs.removeSubrange(earlier..<cut)
            cut = earlier
        }
        return cut
    }

    /// One line of the transcript, or nil for a line that adds nothing.
    private static func piece<S: Said>(_ line: S, name: (S) -> String, label: (S) -> String?) -> String? {
        guard !line.isNote else { return nil }
        switch line.role {
        case .user: return "用户：\(line.text)"
        case .assistant: return line.text.isEmpty ? nil : "\(name(line))：\(line.text)"
        case .tool: return label(line).map { "（用了工具：\($0)）" }
        }
    }

    /// The folded part written out for the digest: 「用户：…」, 「<name>：…」, tools only as a mention. `folded` counts the
    /// messages written out. Use `fitCut` first so it fits; only a single turn longer than `limit` is cut, and then
    /// the transcript says so.
    public static func transcript<S: Said>(_ lines: some Collection<S>, name: (S) -> String, label: (S) -> String?, limit: Int = 60_000) -> (text: String, folded: Int) {
        var out: [String] = []
        var folded = 0
        for line in lines {
            guard let text = piece(line, name: name, label: label) else { continue }
            out.append(text)
            if line.role != .tool { folded += 1 }
        }
        var text = out.joined(separator: "\n")
        if text.count > limit { text = "（下面这一段太长，只留了后半部分）……\n" + String(text.suffix(limit)) }
        return (text, folded)
    }

    /// Undoing a compression: the original lines, then everything said since that the original does not have, without the fold's marker.
    public static func unfolded<S: Said>(original: [S], current: [S], marker: String) -> [S] {
        let known = Set(original.map(\.id))
        return original + current.filter { !known.contains($0.id) && $0.id != marker }
    }
}
