import Foundation

/// Rough token counts, for the 用量 gauge. Services count with their own tokenizers; this only has to be close.
public enum Tokens {
    /// About 0.7 tokens per Chinese or Japanese character, 4 characters per token for Latin text, 1 for anything else (emoji…).
    public static func estimate(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
                wide += 1
            case 0...0x7F, 0x80...0x24F:
                narrow += 1
            default:
                other += 1
            }
        }
        let tokens = Double(wide) * 0.7 + Double(narrow) / 4 + Double(other)
        return Int(tokens.rounded(.up))
    }

    /// How many tokens a model takes in at once, guessed from its name when the person has not said.
    public static func window(for model: String) -> Int {
        let name = model.lowercased()
        if name.contains("gpt-4.1") { return 1_047_576 }
        if name.contains("gemini") { return 1_048_576 }
        if name.contains("gpt-5") { return 400_000 }
        if name.contains("claude") { return 200_000 }
        if name.contains("kimi") || name.contains("moonshot") || name.contains("grok") { return 256_000 }
        if name.contains("qwen") { return 131_072 }
        return 128_000
    }

    /// 657, 15.5K, 1.05M.
    public static func short(_ count: Int) -> String {
        switch count {
        case ..<1000:
            return "\(count)"
        case ..<1_000_000:
            let value = Double(count) / 1000
            return (value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)).replacingOccurrences(of: ".0", with: "") + "K"
        default:
            let value = Double(count) / 1_000_000
            var text = String(format: "%.2f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text + "M"
        }
    }
}
