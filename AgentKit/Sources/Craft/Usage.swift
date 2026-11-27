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

        public var shown: String {
            let formatted = String(format: "%.2f", amount)
            return symbol == "%" ? formatted + symbol : symbol + formatted
        }
    }

    public struct Source: Equatable, Sendable {
        /// Where to ask, with the service's key as a bearer token.
        public var url: URL
        /// Where the user tops up or checks their quota.
        public var topUp: URL
        var usesBareKey = false

        public func authorizationValue(for secret: String) -> String {
            usesBareKey ? secret : "Bearer \(secret)"
        }
    }

    /// Where a service at `baseURL` tells its balance; nil for services that do not.
    public static func source(baseURL: String) -> Source? {
        guard let host = officialHost(baseURL) else { return nil }
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
        switch host {
        case "open.bigmodel.cn", "api.z.ai":
            let console = host == "api.z.ai" ? "https://z.ai/manage-apikey/subscription" : "https://bigmodel.cn/usercenter/pro/overview"
            return Source(url: URL(string: "https://\(host)/api/monitor/usage/quota/limit")!, topUp: URL(string: console)!, usesBareKey: true)
        case "api.stepfun.com":
            return Source(url: URL(string: "https://api.stepfun.com/v1/accounts")!, topUp: URL(string: "https://platform.stepfun.com/account-overview")!)
        case "api.minimaxi.com", "api.minimax.io":
            let console = host == "api.minimaxi.com" ? "https://platform.minimaxi.com" : "https://platform.minimax.io"
            return Source(url: URL(string: "https://\(host)/v1/token_plan/remains")!, topUp: URL(string: console)!)
        case "opencode.ai" where URLComponents(string: baseURL)?.path.hasPrefix("/inference/go/") == true:
            return Source(url: URL(string: "https://opencode.ai/inference/go/v1/usage")!, topUp: URL(string: "https://opencode.ai/console/go")!)
        default:
            return nil
        }
    }

    /// A dashboard can be shown even when the provider has no documented API-key quota endpoint.
    public static func dashboard(baseURL: String) -> URL? {
        switch officialHost(baseURL) {
        case "api-inference.modelscope.cn": return URL(string: "https://modelscope.cn/my/overview")
        case "aihubmix.com", "api.aihubmix.com": return URL(string: "https://console.aihubmix.com/")
        default: return source(baseURL: baseURL)?.topUp
        }
    }

    private static func officialHost(_ baseURL: String) -> String? {
        guard let parts = URLComponents(string: baseURL), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts.host?.lowercased()
    }

    /// Reads the answer of `source(baseURL:)`.
    public static func parse(_ body: String, baseURL: String) -> Reading? {
        guard let host = officialHost(baseURL), let json = JSONValue.parse(body) else { return nil }
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
        let data = json["data"]
        func first(_ values: JSONValue?...) -> Double? {
            values.lazy.compactMap(number).first(where: \.isFinite)
        }
        func reading(_ amount: Double?, _ symbol: String) -> Reading? {
            guard let amount, amount.isFinite else { return nil }
            return Reading(amount: amount, symbol: symbol)
        }
        func remainingPercent(_ used: Double?) -> Reading? {
            guard let used, (0...100).contains(used) else { return nil }
            return reading(100 - used, "%")
        }
        let balance = first(data?["balance"], json["balance"], data?["available_balance"], json["available_balance"])
        switch host {
        case "open.bigmodel.cn", "api.z.ai":
            if let balance {
                let currency = data?["currency"]?.string ?? json["currency"]?.string
                let usd = currency?.uppercased() == "USD" || (currency == nil && host == "api.z.ai")
                return reading(balance, usd ? "$" : "¥")
            }
            guard case .array(let limits)? = data?["limits"] else { return nil }
            let usage = limits.filter { $0["type"]?.string == "TOKENS_LIMIT" }
                .compactMap { number($0["percentage"]) }
                .filter { (0...100).contains($0) }
            return remainingPercent(usage.max())
        case "api.stepfun.com":
            return reading(balance, "¥")
        case "api.minimaxi.com", "api.minimax.io":
            if let status = number(json["base_resp"]?["status_code"]), status != 0 { return nil }
            if let money = first(json["remain_money"], data?["remain_money"], data?["balance"]) {
                return reading(money, host == "api.minimaxi.com" ? "¥" : "$")
            }
            guard case .array(let models)? = json["model_remains"] ?? data?["model_remains"] else { return nil }
            let percentages = models.compactMap { model -> Double? in
                if let percentage = first(model["current_interval_remaining_percent"], model["remaining_percent"]),
                   (0...100).contains(percentage) { return percentage }
                guard let remaining = first(model["remaining"], model["current_interval_usage_count"]),
                      let total = first(model["current_interval_total_count"]), total > 0,
                      (0...total).contains(remaining) else { return nil }
                return 100 * (remaining / total)
            }
            return reading(percentages.min(), "%")
        case "opencode.ai":
            if let credits = first(data?["balance"], json["balance"], data?["credits"], json["credits"], json["remaining"]) {
                return reading(credits, "$")
            }
            let usage = json["usage"]
            let percentages = ["rolling", "weekly", "monthly"].compactMap { field -> Double? in
                guard let percent = number(usage?[field]?["percent"]), (0...100).contains(percent) else { return nil }
                return percent
            }
            return remainingPercent(percentages.max())
        case "api-inference.modelscope.cn":
            return reading(first(data?["remaining_quota"], json["remaining_quota"]) ?? balance, "")
        case "aihubmix.com", "api.aihubmix.com":
            if let credits = first(data?["total_available"], json["total_available"]) { return reading(credits, "$") }
            if let limit = first(json["hard_limit_usd"], data?["hard_limit_usd"]),
               let used = first(json["total_usage"], data?["total_usage"]) {
                return reading(limit - used, "$")
            }
            return reading(first(data?["remain_quota"], json["remain_quota"]), "")
        default:
            return nil
        }
    }
}
