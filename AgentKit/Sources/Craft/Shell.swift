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
        var out = text
        for secret in Set(secrets).filter({ $0.count >= 6 }).sorted(by: { $0.count > $1.count }) where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: hidden)
        }
        return out
    }
}
