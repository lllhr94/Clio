import Foundation

/// 技能: a page of know-how a companion reads when a task calls for it (how to plan a trip, how the user likes a weekly
/// report). Plain Markdown in 书案/技能, with a name and a one-line description on top:
///
///     ---
///     name: 周报
///     description: 用户要写周报时用：按他习惯的格式整理这周做的事
///     ---
///     （正文：怎么做）
public struct Skill: Equatable, Sendable {
    public var name: String
    /// When to use it, in one line: what the companion sees in every conversation.
    public var description: String
    /// The know-how itself, read only when used.
    public var body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }

    /// Reads a skill file. Without the block on top, the name is `fallback` and the description is the first line of text.
    public static func parse(_ text: String, fallback: String) -> Skill {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [String: String] = [:]
        var body = normalized
        if normalized.hasPrefix("---\n"), let end = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) {
            let head = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in head.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                fields[key] = value
            }
            body = String(normalized[end.upperBound...])
            if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) } else { body = "" }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        let rawName = (fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? String(fallback.prefix(80)) : String(rawName.prefix(80))
        let description = fields["description"].flatMap { $0.isEmpty ? nil : $0 } ?? String(firstLine.prefix(100))
        return Skill(name: name, description: description, body: body)
    }

    /// The file a skill is kept as.
    public var text: String {
        let cleanName = String(name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(80))
        return "---\nname: \(cleanName)\ndescription: \(description.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))\n---\n\n\(body)\n"
    }

    /// The lines every conversation carries: name and when to use it, no more.
    public static func menu(_ skills: [Skill], limit: Int = 40) -> String {
        skills.prefix(limit).map { "- \($0.name)：\(String($0.description.prefix(140)))" }.joined(separator: "\n")
    }
}
