import AgentKit
import Craft
import Foundation

extension Endpoint {
    var recipientIdentity: RecipientIdentity? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: base), parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil,
              let origin = EndpointAddressPolicy.rawOrigin(base) else { return nil }
        let prefix = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let route = prefix + (kind == .openai ? "/chat/completions" : "/v1/messages")
        return RecipientIdentity(endpointID: id, canonicalOrigin: origin, protocolKind: kind.rawValue,
                                 route: route, identityRevision: identityRevision)
    }
}

/// A model service Clio knows how to reach: its address, where its keys are made, and how it spells thinking.
/// Anything not listed still works through 自定义, as long as it speaks the OpenAI or the Claude way.
struct Service: Identifiable, Equatable {
    struct Address: Equatable {
        var label: String
        var url: String
    }

    var id: String
    var name: String
    /// One line under the name.
    var note: String
    var kind: Endpoint.Kind
    /// The first is the usual one; others are for other regions.
    var addresses: [Address]
    /// Where to make a key.
    var keyPage: String?
    var style: ThinkingStyle
    /// Used when the service gives no model list, and switched on first when it gives a long one.
    var suggested: [String]
    /// Keep only models whose names start like this.
    var prefix: String?
    /// The service needs the model typed in (it has no list, or names models by your own endpoint).
    var asksModel = false
    /// A hint for that field.
    var modelHint: String?
    /// For 自定义: the address is typed in.
    var custom = false
    /// Several models at once, from many makers.
    var many = false
    /// Runs on the person's own computer: no key needed.
    var keyless = false

    var baseURL: String { addresses.first?.url ?? "" }

    private static let knownDomains: [String: String] = [
        "deepseek": "deepseek.com", "kimi": "kimi.com", "qwen": "tongyi.aliyun.com", "glm": "bigmodel.cn",
        "doubao": "doubao.com", "siliconflow": "siliconflow.cn", "minimax": "minimaxi.com", "openai": "openai.com",
        "claude": "claude.ai", "gemini": "gemini.google.com", "grok": "grok.com", "openrouter": "openrouter.ai",
    ]

    /// The maker's site, for its icon (see `BrandIcon`).
    var domain: String? {
        Self.knownDomains[id]
    }

    /// The tile behind a maker with no icon (自定义, the local one), or until the icon arrives.
    var symbol: String? {
        switch id {
        case "local": "desktopcomputer"
        case "custom", "custom-claude": "slider.horizontal.3"
        default: nil
        }
    }

    static let catalog: [Service] = [
        Service(id: "deepseek", name: "DeepSeek", note: "国内直连，便宜。V4.1 Flash 能看图", kind: .openai,
                addresses: [Address(label: "官方", url: "https://api.deepseek.com")],
                keyPage: "https://platform.deepseek.com/api_keys", style: .deepseek,
                suggested: ["deepseek-flash", "deepseek-v4-pro"], prefix: "deepseek"),
        Service(id: "kimi", name: "Kimi", note: "月之暗面，长上下文", kind: .openai,
                addresses: [Address(label: "国内", url: "https://api.moonshot.cn/v1"), Address(label: "海外", url: "https://api.moonshot.ai/v1")],
                keyPage: "https://platform.moonshot.cn/console/api-keys", style: .kimi,
                suggested: ["kimi-k3", "kimi-k3.1-pro"]),
        Service(id: "qwen", name: "通义千问", note: "阿里云百炼，模型多", kind: .openai,
                addresses: [Address(label: "北京", url: "https://dashscope.aliyuncs.com/compatible-mode/v1"), Address(label: "新加坡", url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")],
                keyPage: "https://bailian.console.aliyun.com/?tab=model#/api-key", style: .qwen,
                suggested: ["qwen-plus", "qwen-flash", "qwen-vl-max"], many: true),
        Service(id: "glm", name: "智谱 GLM", note: "清华系，写代码不错", kind: .openai,
                addresses: [Address(label: "国内", url: "https://open.bigmodel.cn/api/paas/v4"), Address(label: "海外 Z.ai", url: "https://api.z.ai/api/paas/v4")],
                keyPage: "https://open.bigmodel.cn/usercenter/apikeys", style: .glm,
                suggested: ["glm-5.3", "glm-5.3-flash"]),
        Service(id: "doubao", name: "豆包", note: "火山方舟，要先在控制台开通模型", kind: .openai,
                addresses: [Address(label: "北京", url: "https://ark.cn-beijing.volces.com/api/v3")],
                keyPage: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", style: .doubao,
                suggested: [], asksModel: true, modelHint: "模型 ID，比如 doubao-seed-…；或接入点 ep-…"),
        Service(id: "siliconflow", name: "硅基流动", note: "开源模型大全，有免费的", kind: .openai,
                addresses: [Address(label: "国内", url: "https://api.siliconflow.cn/v1"), Address(label: "海外", url: "https://api.siliconflow.com/v1")],
                keyPage: "https://cloud.siliconflow.cn/account/ak", style: .qwen,
                suggested: ["deepseek-ai/DeepSeek-V4.1-Flash", "Qwen/Qwen3.5-397B-A17B", "moonshotai/Kimi-K2.6"], many: true),
        Service(id: "minimax", name: "MiniMax", note: "海螺，能看图，上下文长", kind: .openai,
                addresses: [Address(label: "国内", url: "https://api.minimaxi.com/v1"), Address(label: "海外", url: "https://api.minimax.io/v1")],
                keyPage: "https://platform.minimaxi.com/user-center/basic-information/interface-key", style: .minimax,
                suggested: ["MiniMax-M3", "MiniMax-M3.1-Flash"]),
        Service(id: "openai", name: "OpenAI", note: "GPT 系列；国内要能连外网", kind: .openai,
                addresses: [Address(label: "官方", url: "https://api.openai.com/v1")],
                keyPage: "https://platform.openai.com/api-keys", style: .effort,
                suggested: [], many: true),
        Service(id: "claude", name: "Claude", note: "Anthropic；国内要能连外网", kind: .anthropic,
                addresses: [Address(label: "官方", url: "https://api.anthropic.com")],
                keyPage: "https://console.anthropic.com/settings/keys", style: .none,
                suggested: [], prefix: "claude"),
        Service(id: "gemini", name: "Gemini", note: "Google；国内要能连外网", kind: .openai,
                addresses: [Address(label: "官方", url: "https://generativelanguage.googleapis.com/v1beta/openai")],
                keyPage: "https://aistudio.google.com/apikey", style: .gemini,
                suggested: [], prefix: "gemini", many: true),
        Service(id: "grok", name: "Grok", note: "xAI；国内要能连外网", kind: .openai,
                addresses: [Address(label: "官方", url: "https://api.x.ai/v1")],
                keyPage: "https://console.x.ai", style: .grok,
                suggested: []),
        Service(id: "openrouter", name: "OpenRouter", note: "一个密钥用几百个模型", kind: .openai,
                addresses: [Address(label: "官方", url: "https://openrouter.ai/api/v1")],
                keyPage: "https://openrouter.ai/settings/keys", style: .openrouter,
                suggested: ["deepseek/deepseek-v4.1-flash", "anthropic/claude-sonnet-4.6", "google/gemini-3-flash"], many: true),
        Service(id: "local", name: "自己电脑上的模型", note: "Ollama、LM Studio；手机和电脑连同一个 Wi-Fi", kind: .openai,
                addresses: [Address(label: "", url: "")], keyPage: nil, style: .effort,
                suggested: [], custom: true, keyless: true),
        Service(id: "custom", name: "自定义", note: "别的 OpenAI 兼容服务、中转站、自己搭的", kind: .openai,
                addresses: [Address(label: "", url: "")], keyPage: nil, style: .effort,
                suggested: [], custom: true),
        Service(id: "custom-claude", name: "自定义（Claude 接口）", note: "说 Claude 那种接口的服务", kind: .anthropic,
                addresses: [Address(label: "", url: "")], keyPage: nil, style: .none,
                suggested: [], custom: true),
    ]

    static let byID: [String: Service] = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

    static let byHost: [String: Service] = {
        var map: [String: Service] = [:]
        for service in catalog where !service.custom {
            for address in service.addresses {
                if let host = URL(string: address.url)?.host()?.lowercased(), !host.isEmpty, map[host] == nil {
                    map[host] = service
                }
            }
        }
        return map
    }()

    static func named(_ id: String?) -> Service? {
        guard let id else { return nil }
        return byID[id]
    }

    /// Which listed service an endpoint came from: by its own record, or else by its address.
    static func of(_ endpoint: Endpoint) -> Service? {
        if let known = named(endpoint.service) { return known }
        if let known = named(endpoint.id), !known.custom { return known }
        guard let host = URL(string: endpoint.baseURL)?.host()?.lowercased(), !host.isEmpty else { return nil }
        return byHost[host]
    }

    /// Keeps the models worth showing from what a service listed.
    func keep(_ listed: [String]) -> [String] {
        var models = listed.filter(ModelTraits.isChat)
        if id == "gemini" { models = models.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
        if let prefix { models = models.filter { $0.lowercased().contains(prefix) } }
        return models
    }
}
