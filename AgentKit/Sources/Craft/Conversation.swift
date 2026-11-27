import AgentKit
import Foundation

/// How a conversation is cut and mended before it goes to the model.
public enum Conversation {
    /// Where the part sent to the model begins: the newest messages that fit in `maxChars` (and `maxCount`, when above 0),
    /// moved forward to the next message the user wrote, so the model never starts in the middle of a step.
    /// When no user message follows (a group, where the last word is another companion's), it reaches back to the one before instead,
    /// so the window is never empty.
    public static func windowStart(_ messages: [Message], maxChars: Int, maxCount: Int) -> Int {
        ProtocolAtomicUnit.windowStart(messages, maxChars: maxChars, maxCount: maxCount)
    }

    /// Every tool call gets its answer, even one cut off when a turn was stopped; stray answers are dropped.
    public static func paired(_ messages: [Message]) -> [Message] {
        ProtocolAtomicUnit.paired(messages)
    }
}

/// 雅集: who a companion handed the word to.
public enum Relay {
    /// The member named by a trailing 「@名字」 in a reply (the last line, or the very end of it), never the speaker itself.
    public static func next(after text: String, from speaker: String?, among members: [(id: String, name: String)]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastLine = trimmed.split(separator: "\n").last else { return nil }
        let tail = String(lastLine.suffix(40))
        guard let at = tail.lastIndex(where: { $0 == "@" || $0 == "＠" }) else { return nil }
        let named = tail[tail.index(after: at)...].trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        // Longest name first, so 「小团子」 is not taken for 「团子」.
        for member in members.sorted(by: { $0.name.count > $1.name.count }) where member.id != speaker {
            if named.hasPrefix(member.name) { return member.id }
        }
        return nil
    }
}
