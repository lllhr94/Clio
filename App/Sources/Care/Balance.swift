import AgentKit
import Foundation

/// What is left on a model service's account, for the services that say so.
struct Balance: Equatable {
    var total: Double
    /// 「¥」 or 「$」.
    var currency: String
    /// How the total is made up: 「充值 ¥9.24 · 赠送 ¥0」.
    var detail: String?
    var topUp: URL?

    var shown: String { currency + String(format: "%.2f", total) }
}

enum Balances {
    private struct Service {
        var address: String
        var currency: String
        var topUp: String?
        var read: (JSONValue) -> Balance?
    }

    /// The services with a balance query, recognised by their address.
    private static func service(for endpoint: Endpoint) -> Service? {
        let host = URL(string: endpoint.baseURL)?.host()?.lowercased() ?? ""
        if host.hasSuffix("deepseek.com") {
            return Service(address: "https://api.deepseek.com/user/balance", currency: "¥", topUp: "https://platform.deepseek.com/top_up") { json in
                let infos = json["balance_infos"]?.array ?? []
                guard let info = infos.first(where: { $0["currency"]?.string == "CNY" }) ?? infos.first else { return nil }
                let mark = info["currency"]?.string == "USD" ? "$" : "¥"
                let paid = number(info["topped_up_balance"])
                let given = number(info["granted_balance"])
                return Balance(total: number(info["total_balance"]), currency: mark, detail: "充值 \(mark)\(money(paid)) · 赠送 \(mark)\(money(given))")
            }
        }
        if host.hasSuffix("moonshot.cn") || host.hasSuffix("moonshot.ai") {
            let china = host.hasSuffix(".cn")
            let mark = china ? "¥" : "$"
            return Service(address: "https://\(host)/v1/users/me/balance", currency: mark, topUp: china ? "https://platform.moonshot.cn/console" : "https://platform.moonshot.ai/console") { json in
                guard let data = json["data"] else { return nil }
                return Balance(total: number(data["available_balance"]), currency: mark,
                               detail: "现金 \(mark)\(money(number(data["cash_balance"]))) · 代金券 \(mark)\(money(number(data["voucher_balance"])))")
            }
        }
        if host.hasSuffix("siliconflow.cn") || host.hasSuffix("siliconflow.com") {
            let china = host.hasSuffix(".cn")
            let mark = china ? "¥" : "$"
            return Service(address: "https://\(host)/v1/user/info", currency: mark, topUp: china ? "https://cloud.siliconflow.cn" : "https://cloud.siliconflow.com") { json in
                guard let data = json["data"] else { return nil }
                return Balance(total: number(data["totalBalance"]), currency: mark,
                               detail: "充值 \(mark)\(money(number(data["chargeBalance"]))) · 赠送 \(mark)\(money(number(data["balance"])))")
            }
        }
        if host.hasSuffix("openrouter.ai") {
            return Service(address: "https://openrouter.ai/api/v1/credits", currency: "$", topUp: "https://openrouter.ai/settings/credits") { json in
                guard let data = json["data"] else { return nil }
                let bought = number(data["total_credits"])
                let used = number(data["total_usage"])
                return Balance(total: bought - used, currency: "$", detail: "共充 $\(money(bought)) · 已用 $\(money(used))")
            }
        }
        return nil
    }

    static func supports(_ endpoint: Endpoint) -> Bool { service(for: endpoint) != nil }

    static func currency(_ endpoint: Endpoint) -> String { service(for: endpoint)?.currency ?? "¥" }

    /// Asks the service. Nil when it has no balance query.
    static func check(_ endpoint: Endpoint, key: String) async throws -> Balance? {
        guard let service = service(for: endpoint), let url = URL(string: service.address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ProviderError(status == 401 || status == 403 ? "密钥不对，查不了余额" : "余额没查到（\(status)）")
        }
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)), var balance = service.read(json) else {
            throw ProviderError("余额的格式看不懂")
        }
        balance.topUp = service.topUp.flatMap(URL.init(string:))
        return balance
    }

    /// The person's low-balance line for this service; 0 is off.
    static func alertLine(_ endpoint: Endpoint) -> Double { UserDefaults.standard.double(forKey: "balance.alert." + endpoint.id) }

    static func setAlertLine(_ value: Double, for endpoint: Endpoint) {
        UserDefaults.standard.set(value, forKey: "balance.alert." + endpoint.id)
    }

    /// Services answer with numbers or with numbers in strings.
    private static func number(_ value: JSONValue?) -> Double {
        if let number = value?.number { return number }
        if let text = value?.string, let number = Double(text) { return number }
        return 0
    }

    private static func money(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
