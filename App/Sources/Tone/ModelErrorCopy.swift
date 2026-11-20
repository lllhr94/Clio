import Craft

extension Explain.Advice {
    /// Resolve the short explanation at display time, including notes saved before the tone dictionaries.
    var displayTitle: String {
        let key: String
        switch title {
        case "手机没连上网":
            key = "errors.offline"
        case "这段絮语太长了，模型装不下":
            key = "errors.contextOverflow"
        case let text where text.hasPrefix("等 ") && text.hasSuffix(" 回话等超时了"):
            key = "errors.timeout"
        case let text where text.hasSuffix(" 的密钥不对或已失效"):
            key = "errors.invalidApiKey"
        case let text where text.hasSuffix(" 的账户余额不足"):
            key = "errors.insufficientQuota"
        case let text where text.hasSuffix(" 说请求太频繁"):
            key = "errors.rateLimited"
        case let text where text.contains(" 那边暂时出了问题（") && text.hasSuffix("）"):
            key = "errors.serverError"
        default:
            return title
        }
        return L.t(key)
    }
}
