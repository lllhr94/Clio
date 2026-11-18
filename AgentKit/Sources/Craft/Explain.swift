import AgentKit
import Foundation

/// When something fails: what happened in plain words, and the one thing to do next.
public enum Explain {
    public enum Next: String, Codable, Sendable {
        /// Open 调弦 to fix a key, a model or a service.
        case tuning
        /// Send the same message again.
        case retry
        /// Fold the early part of the conversation.
        case compress
        /// Open 养护 and test the connection.
        case care
        /// Go on with a turn iOS paused in the background.
        case resume
    }

    public struct Advice: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var next: Next?

        public init(title: String, detail: String, next: Next?) {
            self.title = title
            self.detail = detail
            self.next = next
        }

        public var button: String? {
            switch next {
            case .tuning: "去调弦"
            case .retry: "再试一次"
            case .compress: "压缩前文"
            case .care: "去养护里试连"
            case .resume: "接着做"
            case nil: nil
            }
        }
    }

    /// A model call that failed.
    public static func model(_ error: Error, service: String) -> Advice {
        if let failure = error as? ProviderError {
            let words = failure.message.lowercased()
            if words.contains("context") && (words.contains("length") || words.contains("long") || words.contains("maximum")) || words.contains("too many tokens") {
                return Advice(title: "这段絮语太长了，模型装不下", detail: "把较早的部分压成提要，就能接着聊。", next: .compress)
            }
            if words.contains("model") && (words.contains("not exist") || words.contains("not found") || words.contains("does not exist") || words.contains("unknown")) {
                return Advice(title: "\(service) 不认这个模型名", detail: "可能模型已下线或名字写错了。到调弦里换一个模型。", next: .tuning)
            }
            switch failure.status {
            case 401, 403:
                return Advice(title: "\(service) 的密钥不对或已失效", detail: "去调弦里重新填一次密钥。", next: .tuning)
            case 402:
                return Advice(title: "\(service) 的账户余额不足", detail: "去服务商的网站充值后再试。", next: .retry)
            case 429:
                return Advice(title: "\(service) 说请求太频繁", detail: "等一会儿再试；如果一直这样，可能是额度用完了。", next: .retry)
            case 404:
                return Advice(title: "\(service) 的地址或模型不对", detail: "检查调弦里的服务地址和模型名。", next: .tuning)
            case .some(let code) where code >= 500:
                return Advice(title: "\(service) 那边暂时出了问题（\(code)）", detail: "不是你的问题，过一会儿再试。", next: .retry)
            default:
                return Advice(title: "\(service) 拒绝了这次请求", detail: failure.errorDescription ?? failure.message, next: .retry)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return Advice(title: "手机没连上网", detail: "检查 Wi-Fi 或蜂窝数据后再试。", next: .retry)
            case .timedOut:
                return Advice(title: "等 \(service) 回话等超时了", detail: "网络慢或服务忙，再试一次。Claude 这类服务在国内可能需要能连外网。", next: .retry)
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return Advice(title: "找不到 \(service) 的服务器", detail: "地址可能写错了，或者这个服务在当前网络下连不上。", next: .care)
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return Advice(title: "和 \(service) 的加密连接没建起来", detail: "可能是网络被拦截，换个网络试试。", next: .retry)
            default:
                break
            }
        }
        return Advice(title: "这次没回成", detail: error.localizedDescription, next: .retry)
    }
}
