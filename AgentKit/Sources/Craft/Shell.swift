import Foundation

public enum Shell {
    /// Words safe to put inside a shell command as one argument.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Long output keeps its head and its tail, half of `max` each; the middle is left out and counted.
    public static func clip(_ text: String, max: Int = 20_000) -> String {
        guard text.count > max else { return text }
        let half = max / 2
        return String(text.prefix(half)) + "\n……（中间省略 \(text.count - half * 2) 字）……\n" + String(text.suffix(half))
    }

    /// What stands in for a secret.
    public static let hidden = "[已隐去机密]"

    /// Every kept secret that shows up in the text is replaced, longest first, so a model never reads one.
    /// Very short values are left alone: they would match ordinary words.
    public static func mask(_ text: String, secrets: [String]) -> String {
        let valid = Set(secrets).filter { $0.count >= 6 }.sorted { $0.count > $1.count }
        return maskSorted(text, sortedSecrets: valid)
    }

    private static func maskSorted(_ text: String, sortedSecrets: [String]) -> String {
        var out = text
        for secret in sortedSecrets where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: hidden)
        }
        return out
    }

    /// Masks secrets before clipping so a secret straddling the clip boundary never leaks, while staying O(max) on huge text.
    public static func maskedClip(_ text: String, max: Int = 20_000, secrets: [String]) -> String {
        let limit = Swift.max(2, max)
        let valid = Set(secrets).filter { $0.count >= 6 }.sorted { $0.count > $1.count }
        guard let longest = valid.first?.count else {
            return clip(text, max: limit)
        }
        if text.count <= limit * 2 + longest * 2 {
            return clip(maskSorted(text, sortedSecrets: valid), max: limit)
        }
        let half = limit / 2
        let window = half + longest
        let maskedHead = maskSorted(String(text.prefix(window)), sortedSecrets: valid)
        let maskedTail = maskSorted(String(text.suffix(window)), sortedSecrets: valid)
        let headKept = String(maskedHead.prefix(half))
        let tailKept = String(maskedTail.suffix(half))
        let omitted = Swift.max(1, text.count - half * 2)
        return headKept + "\n……（中间省略 \(omitted) 字）……\n" + tailKept
    }
}
