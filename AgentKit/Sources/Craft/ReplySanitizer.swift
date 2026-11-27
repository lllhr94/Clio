import Foundation

public enum ReplySanitizer: Sendable {
    /// Only remove standalone stock phrases at the edges. Keep all other bytes, including whitespace.
    public static func sanitizeReply(_ text: String, antiSlop: Bool) -> String {
        guard antiSlop, !text.isEmpty else { return text }
        let opening = #"\A(?i:(?:of course[!.]|sure[!.]|certainly[!.]|当然可以[！。]|好的[！。]))\r?\n(?:\r?\n)+"#
        let closing = #"(?i:(?:let me know if you have any (?:other )?questions[.!]|i hope this helps[.!]|希望这对你有帮助[。！]|如果你还有其他问题，随时告诉我[。！]))(?:\r?\n)*\z"#
        var result = text.replacingOccurrences(of: opening, with: "", options: .regularExpression)
        // A trailing line inside a fence (including an unclosed fence) is literal code.
        var fence: (marker: Character, length: Int)?
        var hasInlineCode = false
        for line in result.components(separatedBy: "\n") {
            let indentation = line.prefix(while: { $0 == " " }).count
            guard indentation <= 3 else { continue }
            let content = line.dropFirst(indentation)
            guard let marker = content.first else { continue }
            let count = content.prefix(while: { $0 == marker }).count
            guard count >= 3, marker == "`" || marker == "~" else {
                if fence == nil, content.contains("`") { hasInlineCode = true }
                continue
            }
            if let open = fence {
                if open.marker == marker, count >= open.length,
                   content.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
            } else {
                fence = (marker, count)
            }
        }
        if fence == nil, !hasInlineCode, !result.contains("<"),
           let range = result.range(of: #"\r?\n\r?\n"# + closing, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.isEmpty ? text : result
    }

    /// Accepts a display string only. Callers retain the provider's original reasoning for replay.
    public static func formatPublicReasoning(_ text: String, firstPerson: Bool) -> String {
        guard firstPerson else { return text }
        let phrases = [
            ("The user wants ", "I need to help with "),
            ("The user asked me to ", "I need to "),
            ("The assistant should ", "I should "),
            ("用户希望我", "我需要"),
            ("用户希望", "我要处理的是"),
            ("用户想要", "我要处理的是"),
            ("助手应该", "我应该")
        ]
        for (source, replacement) in phrases where text.hasPrefix(source) {
            return replacement + text.dropFirst(source.count)
        }
        return text
    }
}
