import Foundation

/// Shell-style file patterns: `*` within a folder, `**` across folders, `?` one character, `{a,b}` either.
public enum Glob {
    public static func regex(_ pattern: String) -> NSRegularExpression? {
        var out = "^"
        var chars = Array(pattern)
        if chars.first == "/" { chars.removeFirst() }
        var index = 0
        var braces = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        out += "(?:.*/)?"
                        index += 3
                    } else {
                        out += ".*"
                        index += 2
                    }
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0:
                out += "|"
            default:
                out += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        if braces > 0 { return nil }
        return try? NSRegularExpression(pattern: out + "$", options: [.caseInsensitive])
    }

    public static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether a path fits a pattern. A pattern without a slash looks at the file name only.
    public static func matches(_ pattern: String, path: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return matches(regex, pattern.contains("/") ? path : (path as NSString).lastPathComponent)
    }
}
