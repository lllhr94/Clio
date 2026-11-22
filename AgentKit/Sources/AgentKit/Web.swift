import Foundation
import NaturalLanguage
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Turns web pages into text a model can read, and search result pages into a list.
public enum WebText {
    public struct Page: Equatable, Sendable {
        public var title: String
        public var text: String
    }

    public struct Result: Equatable, Sendable {
        public var title: String
        public var url: String
        public var snippet: String
    }

    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        regexLock.lock()
        if let cached = regexCache[pattern] {
            regexLock.unlock()
            return cached
        }
        regexLock.unlock()
        // swiftlint:disable:next force_try
        let compiled = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        regexLock.lock()
        regexCache[pattern] = compiled
        regexLock.unlock()
        return compiled
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func first(_ text: String, _ pattern: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex(pattern).firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    private static func all(_ text: String, _ pattern: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return regex(pattern).matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// `&amp;` and friends, and numbered characters.
    public static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (name, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&ensp;", " "), ("&emsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&middot;", "·"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&copy;", "©")] {
            out = out.replacingOccurrences(of: name, with: value)
        }
        let numeric = regex("&#(?:x([0-9a-f]+)|([0-9]+));")
        let matches = numeric.matches(in: out, range: NSRange(out.startIndex..., in: out))
        if !matches.isEmpty {
            let mutable = NSMutableString(string: out)
            for match in matches.reversed() {
                let value: UInt32?
                if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: out) {
                    value = UInt32(out[r], radix: 16)
                } else if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: out) {
                    value = UInt32(out[r], radix: 10)
                } else {
                    value = nil
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
            out = mutable as String
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Tags gone, entities read, spaces tidied: the words of a piece of HTML on one line.
    public static func plain(_ html: String) -> String {
        let bare = entities(replace(html, "<[^>]+>", with: ""))
        return bare.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Linear-time removal of `<tag ...>...</tag>` blocks, immune to quadratic regex backtracking on unclosed tags.
    private static func stripBlock(_ html: String, tag: String) -> String {
        let openToken = "<" + tag
        let closeToken = "</" + tag
        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let openRange = html.range(of: openToken, options: .caseInsensitive, range: cursor..<html.endIndex) else {
                out.append(contentsOf: html[cursor...])
                break
            }
            let afterName = openRange.upperBound
            let isWordBoundary = afterName == html.endIndex || !html[afterName].isLetter && !html[afterName].isNumber
            guard isWordBoundary else {
                out.append(contentsOf: html[cursor..<afterName])
                cursor = afterName
                continue
            }
            guard let openEnd = html.range(of: ">", range: afterName..<html.endIndex) else {
                out.append(contentsOf: html[cursor...])
                break
            }
            guard let closeRange = html.range(of: closeToken, options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex),
                  let closeEnd = html.range(of: ">", range: closeRange.upperBound..<html.endIndex) else {
                out.append(contentsOf: html[cursor..<openRange.lowerBound])
                out.append(" ")
                cursor = openEnd.upperBound
                continue
            }
            out.append(contentsOf: html[cursor..<openRange.lowerBound])
            out.append(" ")
            cursor = closeEnd.upperBound
        }
        return out
    }

    /// The readable text of a page, its paragraphs kept apart.
    public static func page(_ html: String) -> Page {
        let title = first(html, "<title[^>]*>(.*?)</title>").map(plain) ?? ""
        var body = first(html, "<body[^>]*>(.*)</body>") ?? html
        for tag in ["script", "style", "noscript", "svg", "template", "nav", "footer", "iframe", "form", "button", "select"] {
            body = stripBlock(body, tag: tag)
        }
        body = replace(body, "<!--.*?-->", with: " ")
        body = replace(body, "<li\\b[^>]*>", with: "\n• ")
        body = replace(body, "<(br|hr)\\b[^>]*>", with: "\n")
        body = replace(body, "</?(p|div|section|article|h[1-6]|tr|table|ul|ol|blockquote|pre|header|main|dd|dt|figure|figcaption)\\b[^>]*>", with: "\n")
        body = replace(body, "</t[dh]>", with: " ")
        body = entities(replace(body, "<[^>]+>", with: ""))
        var lines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
            if line.isEmpty || line == "•" {
                if lines.last?.isEmpty == false { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        return Page(title: title, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Bing's result links point at its own redirect; the real address is in `u`, base64 after `a1`.
    public static func unwrapBing(_ link: String) -> String {
        let link = entities(link)
        guard link.contains("bing.com/ck/a"), let encoded = first(link, "[?&]u=a1([^&]+)") else { return link }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let url = String(data: data, encoding: .utf8), url.hasPrefix("http") else { return link }
        return url
    }

    public static func bingResults(_ html: String) -> [Result] {
        var results: [Result] = []
        let chunks = html.components(separatedBy: "class=\"b_algo\"").dropFirst()
        for chunk in chunks {
            let piece = chunk.components(separatedBy: "</li>").first ?? chunk
            guard let anchor = all(piece, "<h2[^>]*>\\s*<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>").first else { continue }
            let url = unwrapBing(anchor[1])
            let title = plain(anchor[2])
            let snippet = plain(first(piece, "<p[^>]*>(.*?)</p>") ?? first(piece, "class=\"b_caption\"[^>]*>(.*?)</div>") ?? "")
            guard url.hasPrefix("http"), !title.isEmpty else { continue }
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    public static func duckResults(_ html: String) -> [Result] {
        var results: [Result] = []
        let chunks = html.components(separatedBy: "class=\"result__body").dropFirst()
        for chunk in chunks {
            guard let anchor = all(chunk, "class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>").first else { continue }
            var url = entities(anchor[1])
            if let wrapped = first(url, "[?&]uddg=([^&]+)"), let real = wrapped.removingPercentEncoding { url = real }
            if url.hasPrefix("//") { url = "https:" + url }
            let snippet = plain(first(chunk, "class=\"result__snippet\"[^>]*>(.*?)</a>") ?? "")
            let title = plain(anchor[2])
            guard url.hasPrefix("http"), !title.isEmpty else { continue }
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// Page bytes as text, in the page's own encoding (many Chinese sites still use GBK).
    public static func decode(_ data: Data, encodingName: String?) -> String {
        func encoding(_ name: String) -> String.Encoding? {
            let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if lower.contains("utf-8") || lower.contains("utf8") { return .utf8 }
            if ["gb2312", "gbk", "gb18030", "x-gbk"].contains(lower) {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            }
            let cf = CFStringConvertIANACharSetNameToEncoding(lower as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        var name = encodingName
        if name == nil {
            let head = String(decoding: data.prefix(4096), as: UTF8.self)
            name = first(head, "<meta[^>]+charset=[\"']?([a-z0-9_-]+)")
        }
        if let name, let found = encoding(name), found != .utf8, let text = String(data: data, encoding: found) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Fetches pages the way a browser would ask for them.
enum WebFetch {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func get(_ url: URL, timeout: TimeInterval = 20) async throws -> (data: Data, type: String?, encoding: String?, url: URL) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if LocalAddress.isLocal(url) {
            throw ProviderError(LocalAddress.refusal)
        }
        if await LocalAddress.resolvesToLocal(url) {
            throw ProviderError(LocalAddress.refusal)
        }
        // Read as it comes, up to a limit: a link to a huge file must not be pulled whole into memory. A redirect to a
        // local or home-network address is not followed (the request would already reach the router or the NAS).
        let (bytes, response) = try await HTTP.session.bytes(for: request, delegate: StayPublic())
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, (300..<400).contains(status) {
            throw ProviderError(status: status, "这个网址要跳到本机或局域网地址，没有跟过去。")
        }
        if let status = http?.statusCode, !(200..<300).contains(status) {
            throw ProviderError(status: status, "网页打不开（\(status)）")
        }
        if response.expectedContentLength > limit {
            throw ProviderError("这个文件太大了（\(ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file))），不读。")
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw ProviderError("这个文件太大了（超过 \(limit / 1_000_000) MB），不读。") }
        }
        return (data, http?.mimeType, http?.textEncodingName, http?.url ?? url)
    }

    /// The most a page or file read from the web may be.
    static let limit = 15_000_000

    /// Performs a public HTTPS JSON API call; redirects are restricted to the exact same HTTPS origin so search queries
    /// and custom auth headers (`x-api-key`, `X-Subscription-Token`, `Authorization`) can never leak to another host or HTTP.
    static func json(_ request: URLRequest, limit: Int = 2_000_000) async throws -> (status: Int, data: Data) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil else {
            throw ProviderError("搜索接口只允许使用 https 地址。")
        }
        if LocalAddress.isLocal(url) {
            throw ProviderError(LocalAddress.refusal)
        }
        if await LocalAddress.resolvesToLocal(url) {
            throw ProviderError(LocalAddress.refusal)
        }
        let (bytes, response) = try await HTTP.session.bytes(for: request, delegate: SameOriginHTTPSRedirect(origin: url))
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (300..<400).contains(status) {
            throw ProviderError(status: status, "搜索接口试图跳转到其他主机或非 https 地址，已中止。")
        }
        if response.expectedContentLength > limit {
            throw ProviderError("搜索返回的内容太大了，已忽略。")
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > limit {
                throw ProviderError("搜索返回的内容太大了，已忽略。")
            }
        }
        return (status, data)
    }

    /// True only when a redirect keeps the exact same public HTTPS origin (scheme, host, port) without embedded credentials.
    static func allowsSameHTTPSOriginRedirect(from origin: URL, to next: URL) -> Bool {
        guard origin.scheme?.lowercased() == "https",
              next.scheme?.lowercased() == "https",
              let originHost = origin.host?.lowercased(),
              let nextHost = next.host?.lowercased(),
              originHost == nextHost,
              (origin.port ?? 443) == (next.port ?? 443),
              next.user == nil, next.password == nil,
              !LocalAddress.isLocal(next) else {
            return false
        }
        return true
    }

    private final class SameOriginHTTPSRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        init(origin: URL) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let next = request.url, WebFetch.allowsSameHTTPSOriginRedirect(from: origin, to: next) else {
                return nil
            }
            if await LocalAddress.resolvesToLocal(next) { return nil }
            return request
        }
    }

    private final class StayPublic: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let next = request.url, !LocalAddress.isLocal(next) else { return nil }
            if await LocalAddress.resolvesToLocal(next) { return nil }
            return request
        }
    }
}

/// Supported web search backends. Built-in Bing / DuckDuckGo is the default; third-party providers are opt-in.
public enum WebSearchProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case builtin
    case anysearch
    case tavily
    case exa
    case brave

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .builtin: "内置网页（Bing / DuckDuckGo）"
        case .anysearch: "AnySearch"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .brave: "Brave"
        }
    }

    public var shortName: String {
        switch self {
        case .builtin: "内置网页"
        case .anysearch: "AnySearch"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .brave: "Brave"
        }
    }

    /// True when this provider requires an API key to run.
    public var needsKey: Bool {
        switch self {
        case .tavily, .exa, .brave: true
        case .anysearch, .builtin: false
        }
    }

    /// True when the user may enter an API key for this provider.
    public var supportsKey: Bool { self != .builtin }

    public var summary: String {
        switch self {
        case .builtin: "默认选项，直接抓取 Bing / DuckDuckGo，不经第三方搜索 API"
        case .anysearch: "免密钥直接可用；填免费密钥每天 1000 次"
        case .tavily: "面向 AI 整理的搜索摘要，免费版每月 1000 次"
        case .exa: "语义搜索，查英文技术文档和论文效果好"
        case .brave: "独立网页索引，响应快、无广告追踪"
        }
    }

    public var consoleHost: String {
        switch self {
        case .builtin: ""
        case .anysearch: "anysearch.com/console/api-keys"
        case .tavily: "app.tavily.com"
        case .exa: "dashboard.exa.ai/api-keys"
        case .brave: "api-dashboard.search.brave.com"
        }
    }
}

/// Active web search configuration loaded for each `web_search` tool invocation.
public struct WebSearchConfig: Sendable, Equatable {
    public var primary: WebSearchProvider
    public var apiKey: String?
    public var fallbackToBuiltin: Bool

    public init(primary: WebSearchProvider = .builtin, apiKey: String? = nil, fallbackToBuiltin: Bool = true) {
        self.primary = primary
        self.apiKey = apiKey
        self.fallbackToBuiltin = fallbackToBuiltin
    }
}

/// Request builders and JSON parsers for structured search APIs.
enum WebSearchAPI {
    static func buildRequest(provider: WebSearchProvider, query: String, apiKey: String?, maxResults: Int = 8) throws -> URLRequest {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch provider {
        case .anysearch:
            let url = URL(string: "https://api.anysearch.com/v1/search")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "max_results": maxResults,
            ])
            return request

        case .tavily:
            guard !trimmedKey.isEmpty else { throw ProviderError("还没有填写 Tavily 的 API 密钥。") }
            let url = URL(string: "https://api.tavily.com/search")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "max_results": maxResults,
                "search_depth": "basic",
            ])
            return request

        case .exa:
            guard !trimmedKey.isEmpty else { throw ProviderError("还没有填写 Exa 的 API 密钥。") }
            let url = URL(string: "https://api.exa.ai/search")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "type": "auto",
                "numResults": maxResults,
                "contents": ["highlights": true],
            ])
            return request

        case .brave:
            guard !trimmedKey.isEmpty else { throw ProviderError("还没有填写 Brave 的 API 密钥。") }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
            let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=\(maxResults)")!
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(trimmedKey, forHTTPHeaderField: "X-Subscription-Token")
            return request

        case .builtin:
            throw ProviderError("内置网页搜索不走 JSON 接口。")
        }
    }

    /// Parses structured search JSON responses while redacting status-only errors (never leaking AnySearch HTTP 402 bodies).
    static func parseResponse(provider: WebSearchProvider, status: Int, data: Data) throws -> [WebText.Result] {
        guard (200..<300).contains(status) else {
            switch (provider, status) {
            case (.anysearch, 402):
                // AnySearch HTTP 402 bodies can contain auto-generated credentials; never surface raw body text.
                throw ProviderError(status: 402, "AnySearch 免费额度暂时用完（HTTP 402）")
            case (_, 401), (_, 403):
                throw ProviderError(status: status, "\(provider.shortName) 密钥无效或无权限（HTTP \(status)）")
            case (_, 402):
                throw ProviderError(status: 402, "\(provider.shortName) 额度已用完（HTTP 402）")
            case (_, 429):
                throw ProviderError(status: 429, "\(provider.shortName) 请求过于频繁或已达限额（HTTP 429）")
            default:
                throw ProviderError(status: status, "\(provider.shortName) 暂时不可用（HTTP \(status)）")
            }
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("\(provider.shortName) 返回的数据格式不对。")
        }

        let rawItems: [[String: Any]]
        switch provider {
        case .anysearch:
            let payload = root["data"] as? [String: Any]
            rawItems = (payload?["results"] as? [[String: Any]]) ?? (root["results"] as? [[String: Any]]) ?? []
        case .tavily, .exa:
            rawItems = (root["results"] as? [[String: Any]]) ?? []
        case .brave:
            let web = root["web"] as? [String: Any]
            rawItems = (web?["results"] as? [[String: Any]]) ?? []
        case .builtin:
            rawItems = []
        }

        var results: [WebText.Result] = []
        var seen: Set<String> = []
        for item in rawItems {
            guard let rawURL = item["url"] as? String else { continue }
            let link = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: link),
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(link).inserted else { continue }

            let rawTitle = (item["title"] as? String) ?? ""
            let title = cleanSnippet(rawTitle, maxChars: 160)
            let finalTitle = title.isEmpty ? (parsed.host ?? link) : title

            let snippet: String
            switch provider {
            case .anysearch:
                let primary = (item["snippet"] as? String) ?? ""
                let fallback = (item["content"] as? String) ?? ""
                snippet = cleanSnippet(primary.isEmpty ? fallback : primary, maxChars: 360)
            case .tavily:
                snippet = cleanSnippet((item["content"] as? String) ?? "", maxChars: 360)
            case .exa:
                let highlights = (item["highlights"] as? [String])?.joined(separator: " ") ?? ""
                let text = (item["text"] as? String) ?? ""
                snippet = cleanSnippet(highlights.isEmpty ? text : highlights, maxChars: 360)
            case .brave:
                let description = (item["description"] as? String) ?? ""
                snippet = cleanSnippet(WebText.plain(description), maxChars: 360)
            case .builtin:
                snippet = ""
            }
            results.append(WebText.Result(title: finalTitle, url: link, snippet: snippet))
        }
        return results
    }

    private static func cleanSnippet(_ raw: String, maxChars: Int) -> String {
        let singleLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > maxChars else { return singleLine }
        return String(singleLine.prefix(maxChars - 1)) + "…"
    }
}

/// Compare the query's significant words with the result title and snippet before accepting a source.
private struct SearchRelevance {
    private let terms: Set<String>
    private static let genericWords: Set<String> = [
        "什么", "怎么", "如何", "哪里", "查询", "官网", "开放", "运营", "时间", "开放时间", "运营时间",
        "今天", "明天", "周六", "周日",
        "a", "an", "the", "and", "or", "for", "how", "what", "when", "where", "to", "in", "of",
    ]

    init(query: String) {
        let words = Self.words(Self.normalized(query))
        let significant = words.subtracting(Self.genericWords)
        terms = significant.isEmpty ? words : significant
    }

    func matches(_ result: WebText.Result) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = Self.normalized(result.title + " " + result.snippet)
        let words = Self.words(text)
        let minimum = min(terms.count, max(2, (terms.count + 1) / 2))
        return terms.lazy.filter { term in
            if term.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                return text.contains(term)
            }
            return words.contains(term)
        }.prefix(minimum).count == minimum
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return Set(tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) })
    }
}

private final class SearchConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var loader: (@Sendable () async -> WebSearchConfig)?

    func set(_ next: (@Sendable () async -> WebSearchConfig)?) {
        lock.lock()
        loader = next
        lock.unlock()
    }

    func load() async -> WebSearchConfig {
        lock.lock()
        let current = loader
        lock.unlock()
        return await current?() ?? WebSearchConfig()
    }
}

/// Searches the web using the configured provider (default: AnySearch free tier) with optional fallback to Bing / DuckDuckGo.
public struct WebSearchTool: AgentTool {
    public struct ProbeResult: Sendable {
        public var ok: Bool
        public var source: String
        public var count: Int
        public var detail: String
    }

    private static let configBox = SearchConfigBox()

    /// Registers a global async config loader (called by the app at launch so every `WebSearchTool()` picks up live settings).
    public static func setConfigLoader(_ loader: (@Sendable () async -> WebSearchConfig)?) {
        configBox.set(loader)
    }

    private let loadConfig: @Sendable () async -> WebSearchConfig
    private let sendJSON: @Sendable (URLRequest) async throws -> (status: Int, data: Data)
    private let fetchHTML: @Sendable (URL) async throws -> String

    public init() {
        loadConfig = { await Self.configBox.load() }
        sendJSON = { try await WebFetch.json($0) }
        fetchHTML = { url in
            let page = try await WebFetch.get(url, timeout: 12)
            return WebText.decode(page.data, encodingName: page.encoding)
        }
    }

    init(fetchHTML: @escaping @Sendable (URL) async throws -> String) {
        loadConfig = { WebSearchConfig(primary: .builtin, apiKey: nil, fallbackToBuiltin: true) }
        sendJSON = { _ in throw ProviderError("测试环境未配置 JSON 搜索。") }
        self.fetchHTML = fetchHTML
    }

    init(
        config: WebSearchConfig,
        sendJSON: @escaping @Sendable (URLRequest) async throws -> (status: Int, data: Data),
        fetchHTML: @escaping @Sendable (URL) async throws -> String = { _ in "" }
    ) {
        loadConfig = { config }
        self.sendJSON = sendJSON
        self.fetchHTML = fetchHTML
    }

    /// Runs a live single-provider probe (no fallback) for the Settings page "试搜一下" check.
    public static func probe(query: String = "Swift", config: WebSearchConfig) async -> ProbeResult {
        var direct = config
        direct.fallbackToBuiltin = false
        let tool = WebSearchTool(
            config: direct,
            sendJSON: { try await WebFetch.json($0) },
            fetchHTML: { url in
                let page = try await WebFetch.get(url, timeout: 12)
                return WebText.decode(page.data, encodingName: page.encoding)
            }
        )
        do {
            let output = try await tool.run(.object(["query": .string(query)]))
            if output.isError {
                return ProbeResult(ok: false, source: config.primary.shortName, count: 0, detail: output.text)
            }
            let lines = output.text.components(separatedBy: "\n")
            let sourceLine = lines.first?.replacingOccurrences(of: "搜索来源：", with: "") ?? config.primary.shortName
            let titles = lines.filter { $0.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil }
            if titles.isEmpty {
                return ProbeResult(ok: false, source: sourceLine, count: 0, detail: output.text)
            }
            let firstTitle = titles[0].replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            return ProbeResult(ok: true, source: sourceLine, count: titles.count, detail: "首条结果：\(firstTitle)")
        } catch {
            return ProbeResult(ok: false, source: config.primary.shortName, count: 0, detail: error.localizedDescription)
        }
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: "在网上搜索，返回标题、链接和摘要。查新闻、价格、天气、事实时用。摘要不够时再用 web_read 读原文。",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "搜索词，简短，像人在搜索框里输入的那样"],
                ],
                "required": ["query"],
            ]
        )
    }

    public func label(for arguments: JSONValue) -> String {
        "搜索：\(arguments["query"]?.string ?? "")"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        guard let query = arguments["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ToolOutput("没有给搜索词。", isError: true)
        }
        let config = await loadConfig()
        var failures: [String] = []

        if config.primary != .builtin {
            do {
                try Task.checkCancellation()
                let request = try WebSearchAPI.buildRequest(provider: config.primary, query: query, apiKey: config.apiKey, maxResults: 8)
                let response = try await sendJSON(request)
                let results = try WebSearchAPI.parseResponse(provider: config.primary, status: response.status, data: response.data)
                if !results.isEmpty {
                    let hasKey = !(config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    let sourceName = (config.primary == .anysearch && !hasKey) ? "AnySearch（免费通道）" : config.primary.shortName
                    return format(results: results, source: sourceName)
                }
                failures.append("\(config.primary.shortName) 未返回结果")
            } catch {
                try Task.checkCancellation()
                failures.append(error.localizedDescription)
            }
            if !config.fallbackToBuiltin {
                return ToolOutput(failures.isEmpty ? "没有搜到结果。" : "搜索失败：\(failures.joined(separator: "；"))", isError: !failures.isEmpty)
            }
        }

        return try await runBuiltin(query: query, priorFailures: failures)
    }

    private func runBuiltin(query: String, priorFailures: [String]) async throws -> ToolOutput {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let relevance = SearchRelevance(query: query)
        var failures = priorFailures
        var hadUnrelatedResults = false
        for (source, address, parse) in [
            ("Bing 国际站", "https://www.bing.com/search?q=\(encoded)&setlang=zh-Hans", WebText.bingResults),
            ("Bing 中国站", "https://cn.bing.com/search?q=\(encoded)", WebText.bingResults),
            ("DuckDuckGo", "https://html.duckduckgo.com/html/?q=\(encoded)", WebText.duckResults),
        ] {
            guard let url = URL(string: address) else { continue }
            do {
                try Task.checkCancellation()
                let raw = parse(try await fetchHTML(url))
                let results = raw.filter(relevance.matches)
                guard !results.isEmpty else {
                    hadUnrelatedResults = hadUnrelatedResults || !raw.isEmpty
                    continue
                }
                return format(results: results, source: source)
            } catch {
                try Task.checkCancellation()
                failures.append(error.localizedDescription)
            }
        }
        if hadUnrelatedResults {
            return ToolOutput("没有找到与搜索词足够相关的结果。可以补上地点、名称或日期再搜。")
        }
        return ToolOutput(failures.isEmpty ? "没有搜到结果。" : "搜索失败：\(failures.joined(separator: "；"))", isError: !failures.isEmpty)
    }

    private func format(results: [WebText.Result], source: String) -> ToolOutput {
        let lines = results.prefix(8).enumerated().map { index, result in
            if result.snippet.isEmpty {
                return "\(index + 1). \(result.title)\n   \(result.url)"
            }
            return "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
        }
        return ToolOutput((["搜索来源：\(source)"] + lines).joined(separator: "\n"))
    }
}

/// Addresses on this phone or its local network. Tools the model drives do not go there: a page could use them
/// to reach the router, a printer, or a service on the phone.
public enum LocalAddress {
    public static let refusal = "这是本机或局域网里的地址，网页工具不去这种地方，只开公网网址。真要看，请用户自己在远游的地址栏里打开。"

    public static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") || (!host.contains(".") && !host.contains(":")) {
            return true
        }
        if host.contains(":") { return isLocalV6(host) }
        // Standard dotted-quad, shorthand (127.1), decimal integer (2130706433), hex (0x7f.0x1), octal (0177.0.0.1).
        var addr4 = in_addr()
        if inet_aton(host, &addr4) != 0 {
            let bytes = withUnsafeBytes(of: &addr4) { Array($0) }
            return bytes.count == 4 ? isLocalV4(bytes) : true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = !parts.isEmpty && parts.allSatisfy { part in
            guard !part.isEmpty else { return false }
            if part.hasPrefix("0x") {
                let hex = part.dropFirst(2)
                return !hex.isEmpty && hex.allSatisfy(\.isHexDigit)
            }
            return part.allSatisfy(\.isNumber)
        }
        return numeric
    }

    /// Resolves `url.host` via DNS and checks whether any resolved IPv4/IPv6 address is local or private.
    public static func resolvesToLocal(_ url: URL) async -> Bool {
        if isLocal(url) { return true }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        // Literal public IPs do not need DNS lookup.
        var a4 = in_addr()
        if inet_aton(host, &a4) != 0 { return false }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, host, &a6) == 1 { return false }
        return await Task.detached(priority: .utility) {
            Self.resolvesHostToLocal(host)
        }.value
    }

    static func resolvesHostToLocal(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return false }
        defer { freeaddrinfo(head) }
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let current = cursor {
            let info = current.pointee
            if let sa = info.ai_addr {
                if info.ai_family == AF_INET {
                    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    let bytes = withUnsafeBytes(of: &sin) { Array($0) }
                    if bytes.count == 4, isLocalV4(bytes) { return true }
                } else if info.ai_family == AF_INET6 {
                    var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: &sin6) { Array($0) }
                    if bytes.count == 16, isLocalV6Bytes(bytes) { return true }
                }
            }
            cursor = info.ai_next
        }
        return false
    }

    static func isLocalV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func isLocalV6(_ host: String) -> Bool {
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            return bytes.count == 16 ? isLocalV6Bytes(bytes) : true
        }
        return true
    }

    static func isLocalV6Bytes(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        // :: (unspecified) and ::1 (loopback)
        let prefixZero = b[0..<15].allSatisfy { $0 == 0 }
        if prefixZero && (b[15] == 0 || b[15] == 1) { return true }
        // fc00::/7 (unique local)
        if (b[0] & 0xfe) == 0xfc { return true }
        // fe80::/10 (link-local: fe80..febf)
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        // ::ffff:0:0/96 (IPv4-mapped IPv6)
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isLocalV4(Array(b[12..<16]))
        }
        // 64:ff9b::/96 (NAT64 well-known prefix)
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 }) {
            return isLocalV4(Array(b[12..<16]))
        }
        return false
    }
}

/// Reads one page as text.
public struct WebReadTool: AgentTool {
    public var limit: Int
    private let fetch: @Sendable (URL) async throws -> (data: Data, type: String?, encoding: String?, url: URL)

    public init(limit: Int = 14000) {
        self.limit = limit
        self.fetch = { try await WebFetch.get($0) }
    }

    init(limit: Int = 14000, fetch: @escaping @Sendable (URL) async throws -> (data: Data, type: String?, encoding: String?, url: URL)) {
        self.limit = limit
        self.fetch = fetch
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_read",
            description: "打开一个网址，读出网页正文。用来读搜索结果的原文、用户发来的链接。也能读 PDF（论文、说明书、报告），长的分段读。",
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "完整网址，以 http 或 https 开头"],
                    "page": ["type": "number", "description": "是 PDF 时，从第几页读起（默认 1）"],
                ],
                "required": ["url"],
            ]
        )
    }

    public func label(for arguments: JSONValue) -> String {
        let address = arguments["url"]?.string ?? ""
        return "读网页：\(URL(string: address)?.host ?? address)"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        var address = arguments["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !address.isEmpty, !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            return ToolOutput("网址不对：\(address)", isError: true)
        }
        if LocalAddress.isLocal(url) { return ToolOutput(LocalAddress.refusal, isError: true) }
        let page = try await fetch(url)
        // A public address can send us on to a local one; what came back from there is not handed over.
        if LocalAddress.isLocal(page.url) { return ToolOutput(LocalAddress.refusal, isError: true) }
        let type = page.type ?? ""
        if type.contains("pdf") || PDFText.looksLike(page.data) {
            let from = (arguments["page"]?.int ?? 1)
            guard let reading = PDFText.read(page.data, from: from, count: 30) else { return ToolOutput("这个 PDF 打不开，可能损坏了或加了密码。", isError: true) }
            var text = reading.shown(limit: limit)
            if reading.read.count > 0, reading.blank.count == reading.read.count {
                text += "\n\n这几页都没有文字层，像是扫描件。可以让用户存到书案，再用 photo_text 一页页认字。"
            }
            return ToolOutput("\(page.url.absoluteString)\n\n" + text)
        }
        if type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/") {
            return ToolOutput("这个链接是\(type)文件，不是网页。", isError: true)
        }
        let source = WebText.decode(page.data, encodingName: page.encoding)
        let isHTML = type.contains("html") || source.range(of: "<html", options: .caseInsensitive) != nil
        let content = isHTML ? WebText.page(source) : WebText.Page(title: "", text: source)
        var text = content.text
        if text.count > limit { text = String(text.prefix(limit)) + "\n……（后面还有，太长截断了）" }
        if text.isEmpty { text = "（这个网页没有读到正文，可能要登录或者靠脚本加载。）" }
        let heading = content.title.isEmpty ? page.url.absoluteString : "\(content.title)\n\(page.url.absoluteString)"
        return ToolOutput("\(heading)\n\n\(text)")
    }
}
