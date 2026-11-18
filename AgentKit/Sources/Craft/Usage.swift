import AgentKit
import Foundation

/// Counting tokens without the model's tokenizer: good enough to say how full the context is.
public enum Tokens {
    /// DeepSeek's rule of thumb: a Chinese character is about 0.6 of a token, any other character about 0.3.
    public static func estimate(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF: wide += 1
            default: narrow += 1
            }
        }
        return Int((Double(wide) * 0.6 + Double(narrow) * 0.3).rounded(.up))
    }

    /// About how many tokens a picture costs a model.
    public static let perImage = 800

    /// A model's context window, by its name. Unknown models get 128K, the common floor.
    public static func window(for model: String) -> Int {
        let name = model.lowercased()
        func has(_ part: String) -> Bool { name.contains(part) }
        if has("deepseek-v4") || name == "deepseek-chat" || name == "deepseek-reasoner" { return 1_048_576 }
        if has("gemini") { return 1_048_576 }
        if has("gpt-4.1") { return 1_047_576 }
        if has("gpt-5") { return 400_000 }
        if has("claude") { return has("1m") ? 1_000_000 : 200_000 }
        if has("kimi") || has("moonshot") { return 262_144 }
        if has("grok-4") { return 256_000 }
        if has("glm-4.6") || has("glm-5") { return 200_000 }
        if has("o3") || has("o4") { return 200_000 }
        return 131_072
    }

    /// 657 · 15.5K · 1.05M
    public static func short(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000:
            let value = Double(count) / 1000
            return (value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)) + "K"
        default:
            return String(format: "%.2f", Double(count) / 1_000_000) + "M"
        }
    }
}

/// What one conversation has cost so far, as the service reported it.
public struct Spend: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    /// Input the service served from its cache (cheaper).
    public var cached = 0
    /// Turns the user started.
    public var turns = 0
    /// Input of the most recent request: the real size of the context last time.
    public var lastInput = 0

    public init() {}

    public mutating func add(input: Int, output: Int, cached: Int) {
        self.input += input
        self.output += output
        self.cached += cached
        if input > 0 { lastInput = input }
    }

    /// Share of the input that came from the cache, 0…1.
    public var cacheShare: Double { input > 0 ? min(1, Double(cached) / Double(input)) : 0 }
}

/// What is left on a model service's account, for the services that say.
public enum Balance {
    public struct Reading: Equatable, Sendable {
        public var amount: Double
        /// ¥ or $.
        public var symbol: String
        /// 「充值 ¥9.24 · 赠送 ¥0.00」
        public var detail: String?

        public init(amount: Double, symbol: String, detail: String? = nil) {
            self.amount = amount
            self.symbol = symbol
            self.detail = detail
        }

        public var shown: String { symbol + String(format: "%.2f", amount) }
    }

    public struct Source: Equatable, Sendable {
        /// Where to ask, with the service's key as a bearer token.
        public var url: URL
        /// Where the user tops up.
        public var topUp: URL
    }

    /// Where a service at `baseURL` tells its balance; nil for services that do not.
    public static func source(baseURL: String) -> Source? {
        guard let host = URL(string: baseURL)?.host()?.lowercased() else { return nil }
        if host == "api.deepseek.com" {
            return Source(url: URL(string: "https://api.deepseek.com/user/balance")!, topUp: URL(string: "https://platform.deepseek.com/top_up")!)
        }
        if host == "openrouter.ai" {
            return Source(url: URL(string: "https://openrouter.ai/api/v1/credits")!, topUp: URL(string: "https://openrouter.ai/settings/credits")!)
        }
        if host == "api.moonshot.cn" || host == "api.moonshot.ai" {
            let china = host.hasSuffix(".cn")
            return Source(url: URL(string: "https://\(host)/v1/users/me/balance")!, topUp: URL(string: china ? "https://platform.moonshot.cn/console" : "https://platform.moonshot.ai/console")!)
        }
        if host == "api.siliconflow.cn" || host == "api.siliconflow.com" {
            let china = host.hasSuffix(".cn")
            return Source(url: URL(string: "https://\(host)/v1/user/info")!, topUp: URL(string: china ? "https://cloud.siliconflow.cn" : "https://cloud.siliconflow.com")!)
        }
        return nil
    }

    /// Reads the answer of `source(baseURL:)`.
    public static func parse(_ body: String, baseURL: String) -> Reading? {
        guard let json = JSONValue.parse(body), let host = URL(string: baseURL)?.host()?.lowercased() else { return nil }
        if host == "api.deepseek.com" {
            guard case .array(let infos)? = json["balance_infos"], !infos.isEmpty else { return nil }
            let info = infos.first { $0["currency"]?.string == "CNY" } ?? infos[0]
            let symbol = info["currency"]?.string == "USD" ? "$" : "¥"
            func amount(_ field: String) -> Double? { info[field]?.string.flatMap { Double($0) } ?? info[field]?.number }
            guard let total = amount("total_balance") else { return nil }
            var parts: [String] = []
            if let topped = amount("topped_up_balance") { parts.append("充值 \(symbol)" + String(format: "%.2f", topped)) }
            if let granted = amount("granted_balance"), granted > 0 { parts.append("赠送 \(symbol)" + String(format: "%.2f", granted)) }
            return Reading(amount: total, symbol: symbol, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
        }
        func number(_ value: JSONValue?) -> Double? { value?.number ?? value?.string.flatMap { Double($0) } }
        func money(_ symbol: String, _ value: Double?) -> String { symbol + String(format: "%.2f", value ?? 0) }
        if host == "api.moonshot.cn" || host == "api.moonshot.ai" {
            let symbol = host.hasSuffix(".cn") ? "¥" : "$"
            guard let data = json["data"], let available = number(data["available_balance"]) else { return nil }
            return Reading(amount: available, symbol: symbol, detail: "现金 " + money(symbol, number(data["cash_balance"])) + " · 代金券 " + money(symbol, number(data["voucher_balance"])))
        }
        if host == "api.siliconflow.cn" || host == "api.siliconflow.com" {
            let symbol = host.hasSuffix(".cn") ? "¥" : "$"
            guard let data = json["data"], let total = number(data["totalBalance"]) else { return nil }
            return Reading(amount: total, symbol: symbol, detail: "充值 " + money(symbol, number(data["chargeBalance"])) + " · 赠送 " + money(symbol, number(data["balance"])))
        }
        if host == "openrouter.ai" {
            guard let data = json["data"], let credits = data["total_credits"]?.number else { return nil }
            let used = data["total_usage"]?.number ?? 0
            return Reading(amount: credits - used, symbol: "$", detail: "共充 $" + String(format: "%.2f", credits) + " · 已用 $" + String(format: "%.2f", used))
        }
        return nil
    }
}
