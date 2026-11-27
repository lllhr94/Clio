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

    /// Extracts `<body ...>...</body>` in O(N) without regex backtracking when `</body>` is missing.
    private static func extractBody(_ html: String) -> String {
        var searchStart = html.startIndex
        while let openTag = html.range(of: "<body", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            let afterName = openTag.upperBound
            let boundary = afterName == html.endIndex || (!html[afterName].isLetter && !html[afterName].isNumber)
            guard boundary else {
                searchStart = afterName
                continue
            }
            guard let openEnd = html.range(of: ">", range: afterName..<html.endIndex) else {
                return html
            }
            if let closeTag = html.range(of: "</body", options: [.caseInsensitive, .backwards], range: openEnd.upperBound..<html.endIndex),
               html.range(of: ">", range: closeTag.upperBound..<html.endIndex) != nil {
                return String(html[openEnd.upperBound..<closeTag.lowerBound])
            }
            return html
        }
        return html
    }

    /// Removes `<!-- ... -->` comments in O(N), stopping immediately if a comment has no closing `-->`.
    private static func stripComments(_ html: String) -> String {
        guard html.contains("<!--") else { return html }
        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard let openRange = html.range(of: "<!--", range: cursor..<html.endIndex) else {
                out.append(contentsOf: html[cursor...])
                break
            }
            out.append(contentsOf: html[cursor..<openRange.lowerBound])
            guard let closeRange = html.range(of: "-->", range: openRange.upperBound..<html.endIndex) else {
                // No closing `-->` exists anywhere in the remainder of `html`.
                out.append(contentsOf: html[openRange.lowerBound...])
                break
            }
            out.append(" ")
            cursor = closeRange.upperBound
        }
        return out
    }

    /// The readable text of a page, its paragraphs kept apart.
    public static func page(_ html: String) -> Page {
        let title = first(html, "<title[^>]*>(.*?)</title>").map(plain) ?? ""
        var body = extractBody(html)
        for tag in ["script", "style", "noscript", "svg", "template", "nav", "footer", "iframe", "form", "button", "select"] {
            body = stripBlock(body, tag: tag)
        }
        body = stripComments(body)
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

    /// Removes balanced `<tag ...>...</tag>` elements whose opening tag satisfies `shouldStrip` in a single O(N) pass.
    private static func stripBalancedContainers(
        _ html: String,
        tag: String,
        placeholder: String = " ",
        shouldStrip: (String) -> Bool
    ) -> String {
        let openToken = "<" + tag
        let closeToken = "</" + tag
        var out = ""
        out.reserveCapacity(html.count)
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard let openStart = findTagStart(in: html, token: openToken, range: cursor..<html.endIndex),
                  let openClose = html.range(of: ">", range: openStart.upperBound..<html.endIndex) else {
                out.append(contentsOf: html[cursor...])
                break
            }
            let openTag = String(html[openStart.lowerBound..<openClose.upperBound])
            guard shouldStrip(openTag) else {
                out.append(contentsOf: html[cursor..<openClose.upperBound])
                cursor = openClose.upperBound
                continue
            }

            out.append(contentsOf: html[cursor..<openStart.lowerBound])
            let scanEnd = scanBalancedTagEnd(
                in: html,
                openToken: openToken,
                closeToken: closeToken,
                from: openClose.upperBound,
                limit: html.endIndex,
                trackListBoundaries: tag.lowercased() == "li"
            )
            out.append(placeholder)
            cursor = scanEnd
        }
        return out
    }

    private static func findTagStart(in html: String, token: String, range: Range<String.Index>) -> Range<String.Index>? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let found = html.range(of: token, options: .caseInsensitive, range: cursor..<range.upperBound) else {
                return nil
            }
            let after = found.upperBound
            if after == range.upperBound || after == html.endIndex || html[after].isWhitespace || html[after] == ">" || html[after] == "/" {
                return found
            }
            cursor = after
        }
        return nil
    }

    /// Scans forward once from `start` within `..<limit` tracking `<tag` / `</tag` depth in strictly linear O(N) time.
    /// When `trackListBoundaries` is enabled (for `<li>`), a sibling `<li>` or closing parent list outside nested
    /// `<ul>`/`<ol>`/`<menu>` implicitly closes an `<li>` whose `</li>` was omitted.
    private static func scanBalancedTagEnd(
        in html: String,
        openToken: String,
        closeToken: String,
        from start: String.Index,
        limit: String.Index,
        trackListBoundaries: Bool = false
    ) -> String.Index {
        var depth = 1
        var listDepth = 0
        var scan = start
        while depth > 0, scan < limit {
            guard let lt = html.range(of: "<", range: scan..<limit) else {
                return limit
            }
            if matchesTagAt(html, index: lt.lowerBound, token: closeToken, limit: limit) {
                let afterToken = html.index(lt.lowerBound, offsetBy: closeToken.count)
                if let closeEnd = html.range(of: ">", range: afterToken..<limit) {
                    depth -= 1
                    scan = closeEnd.upperBound
                } else {
                    return limit
                }
            } else if matchesTagAt(html, index: lt.lowerBound, token: openToken, limit: limit) {
                if trackListBoundaries && listDepth == 0 && depth == 1 {
                    return lt.lowerBound
                }
                let afterToken = html.index(lt.lowerBound, offsetBy: openToken.count)
                if let openEnd = html.range(of: ">", range: afterToken..<limit) {
                    depth += 1
                    scan = openEnd.upperBound
                } else {
                    return limit
                }
            } else if trackListBoundaries, let listCloseLen = matchingListTagLength(html, index: lt.lowerBound, closing: true, limit: limit) {
                if listDepth == 0 && depth == 1 {
                    return lt.lowerBound
                }
                let afterToken = html.index(lt.lowerBound, offsetBy: listCloseLen)
                if let closeEnd = html.range(of: ">", range: afterToken..<limit) {
                    if listDepth > 0 {
                        listDepth -= 1
                        if listDepth == 0 {
                            depth = min(depth, 1)
                        }
                    }
                    scan = closeEnd.upperBound
                } else {
                    return limit
                }
            } else if trackListBoundaries, let listOpenLen = matchingListTagLength(html, index: lt.lowerBound, closing: false, limit: limit) {
                let afterToken = html.index(lt.lowerBound, offsetBy: listOpenLen)
                if let openEnd = html.range(of: ">", range: afterToken..<limit) {
                    listDepth += 1
                    scan = openEnd.upperBound
                } else {
                    return limit
                }
            } else {
                scan = lt.upperBound
            }
        }
        return scan
    }

    private static func matchingListTagLength(_ html: String, index: String.Index, closing: Bool, limit: String.Index) -> Int? {
        let tokens = closing ? ["</ul", "</ol", "</menu"] : ["<ul", "<ol", "<menu"]
        for token in tokens where matchesTagAt(html, index: index, token: token, limit: limit) {
            return token.count
        }
        return nil
    }

    private static func matchesTagAt(_ html: String, index: String.Index, token: String, limit: String.Index) -> Bool {
        guard let tokenEnd = html.index(index, offsetBy: token.count, limitedBy: limit) else { return false }
        guard html[index..<tokenEnd].compare(token, options: .caseInsensitive) == .orderedSame else {
            return false
        }
        return tokenEnd == limit || html[tokenEnd].isWhitespace || html[tokenEnd] == ">" || html[tokenEnd] == "/"
    }

    private static func isAdContainerTag(_ openTag: String) -> Bool {
        let lower = openTag.lowercased()
        let patterns = [
            "\\bb_ad(?:top|bottom|last|_container|s)?\\b",
            "\\bresult--ad\\b",
            "\\bresults_links_ad\\b",
            "\\bad_result\\b",
            "\\bsponsored\\b",
            "\\bad_sc\\b",
            "data-ad(?:v|id|s|-)?\\s*=",
        ]
        return patterns.contains { first(lower, "(\($0))") != nil }
    }

    private static func containsInlineAdMarker(_ piece: String) -> Bool {
        let lower = piece.lowercased()
        let markers = [
            "\\bb_ad(?:top|bottom|last|_container|slug|_label)?\\b",
            "\\bbadge--ad\\b",
            "\\bresult__badge--ad\\b",
            "\\bresult--ad\\b",
            "\\bad[-_](?:badge|slug|label|tag)\\b",
            "data-ad(?:v|id|s|-)?\\s*=",
            "<(?:span|div|i|em|label)[^>]*>\\s*(?:广告|赞助|推广|sponsored|ad)\\s*</(?:span|div|i|em|label)>",
        ]
        return markers.contains { first(lower, "(\($0))") != nil }
    }

    private static let adTrackingHosts: Set<String> = [
        "googleadservices.com", "doubleclick.net", "googlesyndication.com", "adservice.google.com",
        "msads.net", "adnxs.com", "taboola.com", "outbrain.com", "criteo.com",
        "pubmatic.com", "rubiconproject.com", "e.baidu.com", "pos.baidu.com",
        "cpro.baidu.com", "ada.baidu.com", "s.click.taobao.com", "ai.taobao.com",
        "union-click.jd.com", "u.jd.com", "click.linksynergy.com", "anrdoezrs.net",
        "tkqlhce.com", "jdoqocy.com", "dpbolvw.net",
    ]

    /// True when `raw` points to a search ad click redirect, unresolved tracker wrapper, or known ad network.
    static func isAdOrTrackingURL(_ raw: String) -> Bool {
        let cleaned = entities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = cleaned.hasPrefix("//") ? "https:" + cleaned : cleaned
        guard let url = URL(string: normalized), let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        if (host == "bing.com" || host.hasSuffix(".bing.com"))
            && (path.hasPrefix("/aclick") || path.hasPrefix("/ck/a")) {
            return true
        }
        if (host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com"))
            && (path.hasPrefix("/y.js") || path.hasPrefix("/l/")) {
            return true
        }
        if query.contains("ad_domain=") || query.contains("ad_provider=") {
            return true
        }
        return adTrackingHosts.contains { adHost in
            host == adHost || host.hasSuffix("." + adHost)
        }
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

    private static func extractAnchor(in html: String) -> (href: String, titleHTML: String)? {
        guard let match = all(html, "<a\\b([^>]*)>(.*?)</a>").first, match.count >= 3 else { return nil }
        guard let href = first(match[1], "\\bhref\\s*=\\s*[\"']([^\"']+)[\"']") else { return nil }
        return (href, match[2])
    }

    public static func bingResults(_ html: String) -> [Result] {
        var cleaned = stripBalancedContainers(html, tag: "li", shouldStrip: isAdContainerTag)
        cleaned = stripBalancedContainers(cleaned, tag: "div", placeholder: "<span data-ad=\"1\"></span>", shouldStrip: isAdContainerTag)

        var results: [Result] = []
        var seen: Set<String> = []
        let algoPattern = "<(li|div)\\b[^>]*class\\s*=\\s*[\"'][^\"']*\\bb_algo\\b[^\"']*[\"'][^>]*>"
        let matches = regex(algoPattern).matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        for (idx, match) in matches.enumerated() {
            guard let startRange = Range(match.range, in: cleaned),
                  let tagRange = Range(match.range(at: 1), in: cleaned) else { continue }
            let tag = String(cleaned[tagRange]).lowercased()
            let nextStart = idx + 1 < matches.count ? Range(matches[idx + 1].range, in: cleaned)?.lowerBound : nil
            let piece = balancedTagBody(in: cleaned, tag: tag, from: startRange.lowerBound, limit: nextStart ?? cleaned.endIndex)
            guard !containsInlineAdMarker(piece) else { continue }
            guard let h2HTML = first(piece, "<h2[^>]*>(.*?)</h2>"),
                  let anchor = extractAnchor(in: h2HTML) else { continue }
            let rawHref = entities(anchor.href)
            if rawHref.lowercased().contains("bing.com/aclick") { continue }
            let url = unwrapBing(rawHref)
            guard url.hasPrefix("http"), !isAdOrTrackingURL(url) else { continue }
            let title = plain(anchor.titleHTML)
            guard !title.isEmpty, seen.insert(url).inserted else { continue }
            let snippetHTML = first(piece, "<p[^>]*>(.*?)</p>")
                ?? first(piece, "class\\s*=\\s*[\"'][^\"']*\\bb_snippet\\b[^\"']*[\"'][^>]*>(.*?)</div>")
                ?? first(piece, "class\\s*=\\s*[\"'][^\"']*\\bb_caption\\b[^\"']*[\"'][^>]*>(.*?)</div>")
                ?? ""
            let snippet = plain(snippetHTML)
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    public static func duckResults(_ html: String) -> [Result] {
        var cleaned = stripBalancedContainers(html, tag: "div", shouldStrip: isAdContainerTag)
        cleaned = stripBalancedContainers(cleaned, tag: "tr", shouldStrip: isAdContainerTag)

        var results: [Result] = []
        var seen: Set<String> = []
        let bodyPattern = "<div\\b[^>]*class\\s*=\\s*[\"'][^\"']*\\bresult__body\\b[^\"']*[\"'][^>]*>"
        let matches = regex(bodyPattern).matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
        for (idx, match) in matches.enumerated() {
            guard let startRange = Range(match.range, in: cleaned) else { continue }
            let nextStart = idx + 1 < matches.count ? Range(matches[idx + 1].range, in: cleaned)?.lowerBound : nil
            let piece = balancedTagBody(in: cleaned, tag: "div", from: startRange.lowerBound, limit: nextStart ?? cleaned.endIndex)
            guard !containsInlineAdMarker(piece) else { continue }
            guard let anchorMatch = all(piece, "<a\\b([^>]*class\\s*=\\s*[\"'][^\"']*\\bresult__a\\b[^\"']*[\"'][^>]*)>(.*?)</a>").first,
                  anchorMatch.count >= 3,
                  let rawHref = first(anchorMatch[1], "\\bhref\\s*=\\s*[\"']([^\"']+)[\"']") else { continue }
            var url = entities(rawHref)
            if url.lowercased().contains("duckduckgo.com/y.js") || url.lowercased().contains("ad_domain=") { continue }
            if let wrapped = first(url, "[?&]uddg=([^&]+)"), let real = wrapped.removingPercentEncoding { url = real }
            if url.hasPrefix("//") { url = "https:" + url }
            guard url.hasPrefix("http"), !isAdOrTrackingURL(url) else { continue }
            let title = plain(anchorMatch[2])
            guard !title.isEmpty, seen.insert(url).inserted else { continue }
            let snippet = extractDuckSnippet(in: piece)
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    private static func extractDuckSnippet(in piece: String) -> String {
        let pattern = "<(a|div|span)\\b[^>]*class\\s*=\\s*[\"'][^\"']*\\bresult__snippet\\b[^\"']*[\"'][^>]*>"
        let range = NSRange(piece.startIndex..., in: piece)
        guard let match = regex(pattern).firstMatch(in: piece, range: range),
              let fullRange = Range(match.range, in: piece),
              let tagRange = Range(match.range(at: 1), in: piece) else {
            return ""
        }
        let tag = String(piece[tagRange]).lowercased()
        let end = scanBalancedTagEnd(
            in: piece,
            openToken: "<" + tag,
            closeToken: "</" + tag,
            from: fullRange.upperBound,
            limit: piece.endIndex
        )
        return plain(String(piece[fullRange.upperBound..<end]))
    }

    private static func balancedTagBody(in html: String, tag: String, from start: String.Index, limit: String.Index) -> String {
        guard let openEnd = html.range(of: ">", range: start..<limit) else {
            return String(html[start..<limit])
        }
        let end = scanBalancedTagEnd(
            in: html,
            openToken: "<" + tag,
            closeToken: "</" + tag,
            from: openEnd.upperBound,
            limit: limit,
            trackListBoundaries: tag.lowercased() == "li"
        )
        return String(html[start..<end])
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
        let initialEval = await PrivateNetworkPolicy.shared.evaluateAsync(url: url, action: .read, allowAuthorizedPrivate: true)
        if !initialEval.allowed {
            let msg = (initialEval.diagnostic == .fakeIPPlaceholder || initialEval.diagnostic == .mixedDNSAnomaly || initialEval.diagnostic == .scopeEscalationBlocked)
                ? (initialEval.reason ?? LocalAddress.refusal)
                : LocalAddress.refusal
            throw ProviderError(msg)
        }
        // Read as it comes, up to a limit: a link to a huge file must not be pulled whole into memory. A redirect to an
        // unauthorized local or home-network address is not followed.
        do {
            let (bytes, response) = try await HTTP.session.bytes(for: request, delegate: StayPublic(allowAuthorizedPrivate: true))
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
        } catch let error as ProviderError {
            throw error
        } catch {
            if let diag = PrivateNetworkPolicy.diagnoseTransportError(error, url: url) {
                throw ProviderError(diag.userMessage)
            }
            throw error
        }
    }

    /// The most a page or file read from the web may be.
    static let limit = 15_000_000

    /// Performs a public HTTPS JSON API call; redirects are restricted to the exact same HTTPS origin so search queries
    /// and custom auth headers (`x-api-key`, `X-Subscription-Token`, `Authorization`) can never leak to another host or HTTP.
    static func json(_ request: URLRequest, limit: Int = 2_000_000, session: URLSession? = nil) async throws -> (status: Int, data: Data) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil else {
            throw ProviderError("搜索接口只允许使用 https 地址。")
        }
        let hasCreds = request.value(forHTTPHeaderField: "Authorization") != nil
            || request.value(forHTTPHeaderField: "x-api-key") != nil
            || request.value(forHTTPHeaderField: "X-Subscription-Token") != nil
        let eval = await PrivateNetworkPolicy.shared.evaluateAsync(url: url, action: .read, allowAuthorizedPrivate: false, hasCredentials: hasCreds)
        if !eval.allowed {
            let msg = (eval.diagnostic == .fakeIPPlaceholder || eval.diagnostic == .mixedDNSAnomaly || eval.diagnostic == .scopeEscalationBlocked)
                ? (eval.reason ?? LocalAddress.refusal)
                : LocalAddress.refusal
            throw ProviderError(msg)
        }
        let activeSession = session ?? HTTP.session
        let (bytes, response) = try await activeSession.bytes(for: request, delegate: SameOriginHTTPSRedirect(origin: url))
        return try await readJSONBytes(bytes: bytes, response: response, limit: limit)
    }

    /// Performs a user-configured SearXNG JSON search call.
    /// Plain HTTP is allowed ONLY when the user explicitly configured a private/loopback LAN SearXNG base URL;
    /// redirects are locked strictly to the exact same origin (no cross-host, cross-port, or HTTPS->HTTP downgrades).
    static func searxngJSON(_ request: URLRequest, limit: Int = 2_000_000, session: URLSession? = nil) async throws -> (status: Int, data: Data) {
        guard let url = request.url else {
            throw ProviderError(SearXNGError.invalidFormat.localizedDescription)
        }
        let check = SearXNGEndpoint.checkRequestTransport(url)
        guard check.allowed else {
            throw ProviderError(check.errorMessage ?? SearXNGError.requiresHTTPS.localizedDescription)
        }
        if url.scheme?.lowercased() != "https", request.value(forHTTPHeaderField: "Authorization") != nil {
            throw ProviderError("SearXNG 在 http:// 明文连接下不允许发送认证令牌，请改用 https://。")
        }
        if !check.isLAN {
            if LocalAddress.isLocal(url) {
                throw ProviderError(LocalAddress.refusal)
            }
            if await LocalAddress.resolvesToLocal(url) {
                throw ProviderError(LocalAddress.refusal)
            }
        }
        let activeSession = session ?? HTTP.session
        let delegate: URLSessionTaskDelegate = check.isLAN
            ? SameOriginSearXNGRedirect(origin: url)
            : SameOriginHTTPSRedirect(origin: url)
        let (bytes, response) = try await activeSession.bytes(for: request, delegate: delegate)
        return try await readJSONBytes(bytes: bytes, response: response, limit: limit)
    }

    private static func readJSONBytes(bytes: URLSession.AsyncBytes, response: URLResponse, limit: Int) async throws -> (status: Int, data: Data) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (300..<400).contains(status) {
            throw ProviderError(status: status, "搜索接口试图跳转到其他主机或非安全协议地址，已中止。")
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

    /// Redirect policy for user-configured SearXNG instances:
    /// public hosts require exact same HTTPS origin; configured LAN/loopback hosts require exact same scheme+host+port.
    static func allowsSameOriginSearXNGRedirect(from origin: URL, to next: URL, allowLAN: Bool) -> Bool {
        guard allowLAN else {
            return allowsSameHTTPSOriginRedirect(from: origin, to: next)
        }
        guard let originScheme = origin.scheme?.lowercased(),
              let nextScheme = next.scheme?.lowercased(),
              originScheme == nextScheme,
              originScheme == "https" || originScheme == "http",
              let originHost = origin.host?.lowercased(),
              let nextHost = next.host?.lowercased(),
              originHost == nextHost else {
            return false
        }
        let defaultPort = originScheme == "https" ? 443 : 80
        guard (origin.port ?? defaultPort) == (next.port ?? defaultPort),
              next.user == nil, next.password == nil else {
            return false
        }
        if let components = URLComponents(url: next, resolvingAgainstBaseURL: false),
           (components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil) {
            return false
        }
        return SearXNGEndpoint.isAllowedLANHost(nextHost)
    }

    private final class SameOriginHTTPSRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        init(origin: URL) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let next = request.url, WebFetch.allowsSameHTTPSOriginRedirect(from: origin, to: next) else {
                return nil
            }
            let eval = await PrivateNetworkPolicy.shared.evaluateAsync(url: next, action: .read, allowAuthorizedPrivate: false)
            return eval.allowed ? request : nil
        }
    }

    private final class SameOriginSearXNGRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        init(origin: URL) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let next = request.url,
                  WebFetch.allowsSameOriginSearXNGRedirect(from: origin, to: next, allowLAN: true) else {
                return nil
            }
            return request
        }
    }

    fileprivate final class StayPublic: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let allowAuthorizedPrivate: Bool

        init(allowAuthorizedPrivate: Bool = false) {
            self.allowAuthorizedPrivate = allowAuthorizedPrivate
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let next = request.url,
                  let scheme = next.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = next.host, !host.isEmpty,
                  next.user == nil, next.password == nil else { return nil }
            let hasCreds = request.value(forHTTPHeaderField: "Authorization") != nil
                || request.value(forHTTPHeaderField: "Cookie") != nil
            let eval = await PrivateNetworkPolicy.shared.evaluateAsync(
                url: next,
                action: .read,
                allowAuthorizedPrivate: allowAuthorizedPrivate,
                hasCredentials: hasCreds
            )
            guard eval.allowed else { return nil }
            var sanitized = request
            if let prevHost = response.url?.host?.lowercased(), prevHost != host.lowercased() {
                sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
                sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            return sanitized
        }
    }
}

/// Public HTTP fetch helpers guarded against SSRF, private-network redirects, and unbounded downloads.
public enum Web {
    public static func publicBytes(
        from url: URL,
        limit: Int = 32_000_000,
        timeout: TimeInterval = 45,
        session: URLSession? = nil
    ) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ProviderError("不安全的下载地址。")
        }
        let initialEval = await PrivateNetworkPolicy.shared.evaluateAsync(url: url, action: .read, allowAuthorizedPrivate: false)
        if !initialEval.allowed {
            let msg = (initialEval.diagnostic == .fakeIPPlaceholder || initialEval.diagnostic == .mixedDNSAnomaly)
                ? (initialEval.reason ?? LocalAddress.refusal)
                : LocalAddress.refusal
            throw ProviderError(msg)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let activeSession = session ?? HTTP.session
        let (bytes, response) = try await activeSession.bytes(for: request, delegate: WebFetch.StayPublic(allowAuthorizedPrivate: false))
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (300..<400).contains(status) {
            throw ProviderError(status: status, "下载地址试图跳转到本机或局域网，已拒绝。")
        }
        guard (200..<300).contains(status) else {
            throw ProviderError(status: status, "下载失败（\(status)）")
        }
        if response.expectedContentLength > Int64(limit) {
            throw ProviderError("文件过大（超过 \(limit / 1_000_000) MB），已拒绝下载。")
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        for try await byte in bytes {
            if (data.count & 0xFFF) == 0 { try Task.checkCancellation() }
            data.append(byte)
            if data.count > limit {
                throw ProviderError("文件过大（超过 \(limit / 1_000_000) MB），已停止下载。")
            }
        }
        if let finalURL = http?.url {
            let finalEval = PrivateNetworkPolicy.shared.evaluate(url: finalURL, action: .read, allowAuthorizedPrivate: false, resolvedKinds: [])
            if !finalEval.allowed {
                throw ProviderError(LocalAddress.refusal)
            }
        }
        return data
    }
}

/// Validation errors for user-configured SearXNG instance URLs.
public enum SearXNGError: LocalizedError, Equatable, Sendable {
    case empty
    case invalidFormat
    case embeddedCredentials
    case queryOrFragmentNotAllowed
    case requiresHTTPS

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "还没有填写 SearXNG 实例地址。"
        case .invalidFormat:
            return "SearXNG 实例地址格式不对，请填写完整的 http:// 或 https:// 地址。"
        case .embeddedCredentials:
            return "SearXNG 地址不能包含用户名或密码，请先移除链接中的账号信息。"
        case .queryOrFragmentNotAllowed:
            return "SearXNG 地址不要带 ? 查询参数或 # 片段，请只填实例根地址。"
        case .requiresHTTPS:
            return "公网 SearXNG 地址必须使用 https://；只有本机或局域网地址（如 localhost、127.0.0.1、192.168.x.x、10.x.x.x、172.16–31.x.x、.local）允许使用 http://。"
        }
    }
}

/// Validates and normalizes custom SearXNG instance base URLs and request URLs.
public enum SearXNGEndpoint {
    public struct Parsed: Equatable, Sendable {
        public let baseURL: String
        public let searchBaseURL: String
        public let originKey: String
        public let isLAN: Bool
    }

    /// Returns true if the raw text appears to embed `user[:pass]@` authority credentials.
    public static func containsEmbeddedCredentials(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let components = URLComponents(string: trimmed),
           (components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil) {
            return true
        }
        let withoutScheme: Substring
        if let range = trimmed.range(of: "://") {
            withoutScheme = trimmed[range.upperBound...]
        } else {
            withoutScheme = Substring(trimmed)
        }
        let authority = withoutScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return authority.contains("@")
    }

    /// Parses, validates, and strips trailing slashes from a custom SearXNG instance URL.
    public static func parse(_ raw: String) -> Result<Parsed, SearXNGError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure(.invalidFormat)
        }
        if containsEmbeddedCredentials(trimmed) {
            return .failure(.embeddedCredentials)
        }
        if trimmed.contains("?") || trimmed.contains("#") {
            return .failure(.queryOrFragmentNotAllowed)
        }
        guard trimmed.contains("://"), var components = URLComponents(string: trimmed) else {
            return .failure(.invalidFormat)
        }
        if components.user != nil || components.password != nil
            || components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return .failure(.embeddedCredentials)
        }
        if components.query != nil || components.percentEncodedQuery != nil
            || components.fragment != nil || components.percentEncodedFragment != nil {
            return .failure(.queryOrFragmentNotAllowed)
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let rawHost = components.host, !rawHost.isEmpty else {
            return .failure(.invalidFormat)
        }
        if let port = components.port, !(1...65535).contains(port) {
            return .failure(.invalidFormat)
        }
        if isDisallowedSpecialHost(rawHost) {
            return .failure(.invalidFormat)
        }
        let lan = isAllowedLANHost(rawHost)
        if scheme == "http" && !lan {
            return .failure(.requiresHTTPS)
        }
        components.scheme = scheme
        if rawHost.contains(":") {
            if let encodedHost = components.percentEncodedHost?.lowercased() {
                if encodedHost.hasPrefix("[") && encodedHost.hasSuffix("]") {
                    components.percentEncodedHost = encodedHost
                } else {
                    components.percentEncodedHost = "[\(cleanHostToken(encodedHost))]"
                }
            }
        } else {
            components.host = rawHost.lowercased()
        }

        var cleanPath = components.path
        while cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        components.path = cleanPath
        guard let canonicalBase = components.url, let key = originKey(for: canonicalBase) else {
            return .failure(.invalidFormat)
        }

        var searchComponents = components
        if !cleanPath.lowercased().hasSuffix("/search") {
            searchComponents.path = cleanPath + "/search"
        }
        guard let searchBase = searchComponents.url else {
            return .failure(.invalidFormat)
        }
        return .success(Parsed(
            baseURL: canonicalBase.absoluteString,
            searchBaseURL: searchBase.absoluteString,
            originKey: key,
            isLAN: lan
        ))
    }

    /// Canonical `scheme://host:effectivePort` key for binding SearXNG Bearer tokens to an exact origin.
    public static func originKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return nil
        }
        let bareHost = (rawHost.hasPrefix("[") && rawHost.hasSuffix("]"))
            ? String(rawHost.dropFirst().dropLast())
            : rawHost
        let formattedHost = bareHost.contains(":") ? "[\(bareHost)]" : bareHost
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        return "\(scheme)://\(formattedHost):\(port)"
    }

    /// Canonical `scheme://host:effectivePort` key computed from a validated SearXNG base URL string.
    public static func originKey(forBaseURL raw: String) -> String? {
        try? parse(raw).get().originKey
    }

    /// Convenience wrapper returning the canonical normalized base URL when valid.
    public static func normalize(_ raw: String) -> String? {
        try? parse(raw).get().baseURL
    }

    /// Builds `<base>/search?q=...&format=json` from a validated SearXNG base URL.
    public static func buildSearchURL(baseURL: String, query: String) throws -> URL {
        let parsed: Parsed
        switch parse(baseURL) {
        case .success(let value):
            parsed = value
        case .failure(let error):
            throw ProviderError(error.localizedDescription)
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        guard var components = URLComponents(string: parsed.searchBaseURL) else {
            throw ProviderError(SearXNGError.invalidFormat.localizedDescription)
        }
        components.percentEncodedQuery = "q=\(encoded)&format=json"
        guard let url = components.url else {
            throw ProviderError(SearXNGError.invalidFormat.localizedDescription)
        }
        return url
    }

    /// Verifies transport security for an assembled SearXNG request URL.
    static func checkRequestTransport(_ url: URL) -> (allowed: Bool, isLAN: Bool, errorMessage: String?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil else {
            return (false, false, SearXNGError.invalidFormat.localizedDescription)
        }
        if isDisallowedSpecialHost(host) {
            return (false, false, SearXNGError.invalidFormat.localizedDescription)
        }
        let lan = isAllowedLANHost(host)
        if scheme == "http" && !lan {
            return (false, false, SearXNGError.requiresHTTPS.localizedDescription)
        }
        return (true, lan, nil)
    }

    /// True ONLY for explicit private/loopback LAN hosts allowed over `http://` when configured for SearXNG:
    /// `localhost`, `*.localhost`, `*.local`, `*.lan`, `*.internal`, `*.home.arpa`,
    /// IPv4 private/loopback/CGNAT (`127/8`, `10/8`, `172.16-31/12`, `192.168/16`, `100.64-127/10`),
    /// and IPv6 loopback/ULA/link-local (`::1`, `fc00::/7`, `fe80::/10`, `::ffff:<private-v4>`).
    public static func isAllowedLANHost(_ rawHost: String) -> Bool {
        let host = cleanHostToken(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".lan") || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return true
        }
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let bytes = withUnsafeBytes(of: &addr4) { Array($0) }
            return bytes.count == 4 && isPrivateOrLoopbackV4(bytes)
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
            return bytes.count == 16 && isPrivateOrLoopbackV6(bytes)
        }
        return false
    }

    private static func isDisallowedSpecialHost(_ rawHost: String) -> Bool {
        let host = cleanHostToken(rawHost)
        guard !host.isEmpty else { return true }
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let b = withUnsafeBytes(of: &addr4) { Array($0) }
            guard b.count == 4 else { return true }
            if b[0] == 0 || b[0] >= 224 { return true }
            if b[0] == 169 && b[1] == 254 { return true }
            return false
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let b = withUnsafeBytes(of: &addr6) { Array($0) }
            guard b.count == 16 else { return true }
            if b.allSatisfy({ $0 == 0 }) { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                let mapped = Array(b[12..<16])
                if mapped[0] == 0 || mapped[0] >= 224 || (mapped[0] == 169 && mapped[1] == 254) { return true }
            }
            return false
        }
        return false
    }

    private static func cleanHostToken(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    private static func isPrivateOrLoopbackV4(_ b: [UInt8]) -> Bool {
        b[0] == 127
            || b[0] == 10
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1]))
    }

    private static func isPrivateOrLoopbackV6(_ b: [UInt8]) -> Bool {
        let isLoopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        if isLoopback { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivateOrLoopbackV4(Array(b[12..<16]))
        }
        return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
    }
}

/// Supported web search backends. Built-in Bing / DuckDuckGo is the default; third-party and self-hosted providers are opt-in.
public enum WebSearchProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case builtin
    case anysearch
    case tavily
    case exa
    case brave
    case searxng

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .builtin: "内置网页（Bing / DuckDuckGo）"
        case .anysearch: "AnySearch"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .brave: "Brave"
        case .searxng: "SearXNG（自建实例）"
        }
    }

    public var shortName: String {
        switch self {
        case .builtin: "内置网页"
        case .anysearch: "AnySearch"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .brave: "Brave"
        case .searxng: "SearXNG"
        }
    }

    /// True when this provider requires an API key to run.
    public var needsKey: Bool {
        switch self {
        case .tavily, .exa, .brave: true
        case .anysearch, .builtin, .searxng: false
        }
    }

    /// True when the user may enter an API key (or optional Bearer token) for this provider.
    public var supportsKey: Bool { self != .builtin }

    /// True when this provider requires a user-configured instance base URL.
    public var needsURL: Bool { self == .searxng }

    public var summary: String {
        switch self {
        case .builtin: "默认选项，直接抓取 Bing / DuckDuckGo，不经第三方搜索 API"
        case .anysearch: "免密钥直接可用；填免费密钥每天 1000 次"
        case .tavily: "面向 AI 整理的搜索摘要，免费版每月 1000 次"
        case .exa: "语义搜索，查英文技术文档和论文效果好"
        case .brave: "独立网页索引，响应快、无广告追踪"
        case .searxng: "连接自建 SearXNG 实例（支持公网 HTTPS 或局域网 HTTP）"
        }
    }

    public var consoleHost: String {
        switch self {
        case .builtin, .searxng: ""
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
    public var apiKeys: [WebSearchProvider: String]
    public var searxngURL: String?
    public var fallbackOrder: [WebSearchProvider]
    /// Canonical `scheme://host:port` origin that the SearXNG Bearer token is bound to (if set).
    public var searxngKeyOrigin: String?

    public init(
        primary: WebSearchProvider = .builtin,
        apiKey: String? = nil,
        fallbackToBuiltin: Bool = true,
        apiKeys: [WebSearchProvider: String] = [:],
        searxngURL: String? = nil,
        fallbackOrder: [WebSearchProvider] = [],
        searxngKeyOrigin: String? = nil
    ) {
        self.primary = primary
        self.apiKey = apiKey
        self.fallbackToBuiltin = fallbackToBuiltin
        self.apiKeys = apiKeys
        self.searxngURL = searxngURL
        self.fallbackOrder = fallbackOrder
        self.searxngKeyOrigin = searxngKeyOrigin
    }

    /// Effective deduplicated provider chain: `primary`, followed by `fallbackOrder`,
    /// then `.builtin` at the end if `fallbackToBuiltin` is true and `.builtin` is not yet included.
    public var searchChain: [WebSearchProvider] {
        var chain: [WebSearchProvider] = [primary]
        var seen: Set<WebSearchProvider> = [primary]
        for provider in fallbackOrder where seen.insert(provider).inserted {
            chain.append(provider)
        }
        if fallbackToBuiltin && !seen.contains(.builtin) {
            chain.append(.builtin)
        }
        return chain
    }

    /// Resolves the API key for a given provider (checking `apiKeys` first, then `apiKey` for `primary`).
    /// For `.searxng`, requires an `https://` base URL and refuses to return a token if `searxngKeyOrigin`
    /// does not match `searxngURL`'s exact origin.
    public func key(for provider: WebSearchProvider) -> String? {
        let candidate: String?
        if let mapped = apiKeys[provider]?.trimmingCharacters(in: .whitespacesAndNewlines), !mapped.isEmpty {
            candidate = mapped
        } else if provider == primary, let legacy = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            candidate = legacy
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        if provider == .searxng {
            guard let rawURL = searxngURL,
                  case .success(let parsed) = SearXNGEndpoint.parse(rawURL),
                  parsed.baseURL.lowercased().hasPrefix("https://") else {
                return nil
            }
            if let expectedOrigin = searxngKeyOrigin, parsed.originKey != expectedOrigin {
                return nil
            }
        }
        return candidate
    }
}

/// Request builders and JSON parsers for structured search APIs.
enum WebSearchAPI {
    static func buildRequest(
        provider: WebSearchProvider,
        query: String,
        apiKey: String?,
        searxngURL: String? = nil,
        maxResults: Int = 8
    ) throws -> URLRequest {
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

        case .searxng:
            let url = try SearXNGEndpoint.buildSearchURL(baseURL: searxngURL ?? "", query: query)
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(WebFetch.agent, forHTTPHeaderField: "User-Agent")
            if !trimmedKey.isEmpty {
                guard url.scheme?.lowercased() == "https" else {
                    throw ProviderError("SearXNG 仅在使用 https:// 地址时允许发送 Bearer 令牌。")
                }
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }
            return request

        case .builtin:
            throw ProviderError("内置网页搜索不走 JSON 接口。")
        }
    }

    /// Parses structured search JSON responses while redacting status-only errors (never leaking AnySearch HTTP 402 bodies).
    static func parseResponse(provider: WebSearchProvider, status: Int, data: Data, maxResults: Int = 8) throws -> [WebText.Result] {
        guard (200..<300).contains(status) else {
            switch (provider, status) {
            case (.anysearch, 402):
                // AnySearch HTTP 402 bodies can contain auto-generated credentials; never surface raw body text.
                throw ProviderError(status: 402, "AnySearch 免费额度暂时用完（HTTP 402）")
            case (.searxng, 403):
                throw ProviderError(status: 403, "SearXNG 拒绝了 JSON 请求（HTTP 403），请检查令牌或是否在 settings.yml 开启 json 格式")
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
        case .tavily, .exa, .searxng:
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
            guard results.count < maxResults else { break }
            guard let rawURL = item["url"] as? String else { continue }
            let link = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: link),
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !WebText.isAdOrTrackingURL(link),
                  seen.insert(link).inserted else { continue }

            let rawTitle = (item["title"] as? String) ?? ""
            let cleanedTitleSource = provider == .searxng ? WebText.plain(rawTitle) : rawTitle
            let title = cleanSnippet(cleanedTitleSource, maxChars: 160)
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
            case .searxng:
                let content = (item["content"] as? String) ?? ""
                let fallback = (item["snippet"] as? String) ?? ""
                let rawSnippet = content.isEmpty ? fallback : content
                snippet = cleanSnippet(WebText.plain(rawSnippet), maxChars: 360)
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

/// Evaluates CJK, ASCII, and Unicode word relevance overlap across title, snippet, and domain while filtering off-topic SEO spam.
struct SearchRelevance {
    private enum Term: Hashable {
        case word(whole: String, parts: [String])
        case cjk(text: String, bigrams: [String])
    }

    private let terms: [Term]
    private let normalizedQuery: String

    private static let genericWords: Set<String> = [
        "什么", "怎么", "怎样", "如何", "哪里", "哪儿", "哪个", "哪些", "为什么", "多少", "多少钱", "费用",
        "价格", "售价", "查询", "查一下", "官网", "官方", "官方网站", "开放", "运营", "时间", "开放时间",
        "运营时间", "营业时间", "今天", "明天", "昨天", "今日", "明日", "昨日", "本周", "本月", "今年", "现在", "最新", "最近", "周六", "周日", "周末",
        "请问", "帮我", "推荐", "排行", "排行榜", "怎么样", "好不好", "是什么", "是什么意思", "怎么用",
        "教程", "攻略", "介绍", "简介", "下载", "的", "了", "吗", "呢", "吧", "啊", "呀", "和", "与", "或",
        "在", "是", "有", "去", "到", "从", "对", "把", "被", "给", "为", "向", "关于", "以及",
        "a", "an", "the", "and", "or", "for", "how", "what", "when", "where", "who", "which", "why",
        "to", "in", "of", "on", "at", "by", "from", "with", "is", "are", "was", "were", "be", "can",
        "do", "does", "did", "official", "website", "price", "time", "hours", "today", "latest", "guide", "tutorial",
        "в", "и", "на", "с", "по", "о", "об", "за", "из", "к", "от", "для", "как", "что", "где", "когда",
    ]

    private static let suffixStopwords: [String] = [
        "开放时间", "运营时间", "营业时间", "是什么意思", "在哪里", "多少钱", "怎么样", "是什么", "怎么用", "好不好",
    ]

    private static let synonyms: [String: [String]] = [
        "ai": ["人工智能", "大模型", "智能"],
        "人工智能": ["ai", "智能"],
        "天气": ["气温", "气象", "天气预报", "降水", "晴", "多云", "小雨", "大雨", "预报"],
        "气温": ["天气", "温度", "预报"],
        "截屏": ["截图", "屏幕快照"],
        "截图": ["截屏", "屏幕快照"],
        "猫咪": ["猫", "小猫", "喵星人"],
        "猫": ["猫咪", "小猫"],
        "狗狗": ["狗", "小狗"],
        "狗": ["狗狗", "小狗"],
        "iphone": ["苹果手机"],
        "苹果手机": ["iphone"],
        "macbook": ["苹果笔记本"],
        "苹果笔记本": ["macbook"],
        "地铁": ["轨交", "轨道交通"],
        "高铁": ["动车", "铁路"],
        "开放": ["开馆", "营业"],
    ]

    private static let datingSpamSignals = [
        "同城交友", "附近约会", "约会神器", "单身交友", "交友软件", "交友app", "陌陌", "探探",
        "陪聊", "美女直播", "同城约", "一夜情", "裸聊",
    ]
    private static let datingQueryHints = ["交友", "约会", "陌陌", "探探", "直播", "社交", "婚恋", "相亲"]

    private static let gamblingSpamSignals = [
        "博彩", "威尼斯人", "太阳城", "开奖直播", "六合彩", "棋牌娱乐", "真人娱乐", "ag真人", "老虎机", "赌博",
    ]
    private static let gamblingQueryHints = ["博彩", "彩票", "开奖", "棋牌", "赌博"]

    private static let mediaSpamSignals = [
        "樱花动漫", "风车动漫", "在线观看完整版", "免费观看高清", "高清无删减", "未删减完整版",
        "影视大全免费", "动漫全集免费", "免费看番",
    ]
    private static let mediaQueryHints = [
        "动漫", "番剧", "动画", "视频", "电影", "影视", "在线观看", "樱花", "风车", "anime", "漫画",
    ]

    init(query: String) {
        let norm = Self.normalized(query)
        self.normalizedQuery = norm
        let rawTerms = Self.extractTerms(from: norm)
        var filtered: [Term] = []
        for term in rawTerms {
            switch term {
            case .word(let whole, _):
                if !Self.genericWords.contains(whole) {
                    filtered.append(term)
                }
            case .cjk(let text, _):
                if !Self.genericWords.contains(text) {
                    filtered.append(term)
                }
            }
        }
        self.terms = filtered.isEmpty ? rawTerms : filtered
    }

    func matches(_ result: WebText.Result) -> Bool {
        score(result) != nil
    }

    func score(_ result: WebText.Result) -> Double? {
        if isOffTopicSpam(result) { return nil }
        guard !terms.isEmpty else { return 1.0 }
        let domain = Self.domainText(from: result.url)
        let candidateAll = Self.normalized(result.title + " " + result.snippet + " " + domain)
        let candidateWords = Self.extractWordSet(from: candidateAll)

        var scores: [Double] = []
        scores.reserveCapacity(terms.count)
        for term in terms {
            scores.append(score(term: term, candidateAll: candidateAll, candidateWords: candidateWords))
        }

        let avg = scores.reduce(0, +) / Double(scores.count)
        let strongMatches = scores.filter { $0 >= 0.7 }.count
        let anyMatches = scores.filter { $0 >= 0.5 }.count

        switch terms.count {
        case 1:
            return avg >= 0.65 ? avg : nil
        case 2:
            let ok = (anyMatches == 2 && avg >= 0.65) || (strongMatches >= 1 && avg >= 0.65)
            return ok ? avg : nil
        default:
            let required = min(terms.count, max(2, (terms.count + 1) / 2))
            let ok = anyMatches >= required && strongMatches >= 1
            return ok ? avg : nil
        }
    }

    private func isOffTopicSpam(_ result: WebText.Result) -> Bool {
        let combined = Self.normalized(result.title + " " + result.snippet + " " + result.url)
        if !Self.datingQueryHints.contains(where: { normalizedQuery.contains($0) }),
           Self.datingSpamSignals.contains(where: { combined.contains($0) }) {
            return true
        }
        if !Self.gamblingQueryHints.contains(where: { normalizedQuery.contains($0) }),
           Self.gamblingSpamSignals.contains(where: { combined.contains($0) }) {
            return true
        }
        if !Self.mediaQueryHints.contains(where: { normalizedQuery.contains($0) }),
           Self.mediaSpamSignals.contains(where: { combined.contains($0) }) {
            return true
        }
        return false
    }

    private func score(term: Term, candidateAll: String, candidateWords: Set<String>) -> Double {
        switch term {
        case .word(let whole, let parts):
            if candidateWords.contains(whole) { return 1.0 }
            if !parts.isEmpty {
                let matchedParts = parts.filter { candidateWords.contains($0) }.count
                if matchedParts == parts.count { return 1.0 }
                if matchedParts > 0 { return Double(matchedParts) / Double(parts.count) }
            }
            if whole.count >= 4, candidateWords.contains(where: { $0.contains(whole) }) {
                return 0.85
            }
            if !whole.unicodeScalars.allSatisfy(\.isASCII), whole.count >= 5 {
                let stem = String(whole.prefix(whole.count - 1))
                if candidateWords.contains(where: { $0.hasPrefix(stem) }) {
                    return 0.85
                }
            }
            if let syns = Self.synonyms[whole] {
                for syn in syns where matchesSynonym(syn, in: candidateAll, words: candidateWords) {
                    return 0.8
                }
            }
            return 0.0

        case .cjk(let text, let bigrams):
            if candidateAll.contains(text) { return 1.0 }
            if text.count >= 3 && !bigrams.isEmpty {
                let hitCount = bigrams.filter { candidateAll.contains($0) }.count
                if hitCount > 0 {
                    return Double(hitCount) / Double(bigrams.count)
                }
            }
            if let syns = Self.synonyms[text] {
                for syn in syns where matchesSynonym(syn, in: candidateAll, words: candidateWords) {
                    return 0.85
                }
            }
            return 0.0
        }
    }

    private func matchesSynonym(_ syn: String, in candidateAll: String, words: Set<String>) -> Bool {
        if syn.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return words.contains(syn)
        }
        return candidateAll.contains(syn)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        #if canImport(Darwin)
        return folded.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? folded
        #else
        return folded
        #endif
    }

    private static func domainText(from rawURL: String) -> String {
        guard let url = URL(string: rawURL), var host = url.host?.lowercased() else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let labels = host.split(separator: ".").map(String.init)
        let tlds: Set<String> = ["com", "org", "net", "cn", "io", "co", "gov", "edu", "me", "dev", "app", "ai", "jp", "uk", "de", "fr", "hk", "tw"]
        let meaningful = labels.filter { !tlds.contains($0) && $0.count > 1 }
        return ([host] + meaningful).joined(separator: " ")
    }

    private static func isCJKOrKanaOrHangul(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        let v = scalar.value
        return (0x3040...0x30FF).contains(v)
            || (0x31F0...0x31FF).contains(v)
            || (0xAC00...0xD7AF).contains(v)
            || (0x1100...0x11FF).contains(v)
            || (0x3130...0x318F).contains(v)
    }

    private static func isASCIITokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    private static func isUnicodeWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let props = scalar.properties
        return props.isAlphabetic
            || props.numericType != nil
            || props.generalCategory == .nonspacingMark
            || props.generalCategory == .spacingMark
    }

    private static func extractTerms(from norm: String) -> [Term] {
        var result: [Term] = []
        var seen: Set<Term> = []

        func appendTerm(_ term: Term) {
            if seen.insert(term).inserted {
                result.append(term)
            }
        }

        enum ScriptKind { case ascii, cjk, unicode, separator }
        var current = ""
        var currentKind: ScriptKind = .separator

        func flush() {
            guard !current.isEmpty else { return }
            let token = current
            current = ""
            switch currentKind {
            case .ascii:
                let parts = splitAlphaDigitParts(token)
                appendTerm(.word(whole: token, parts: parts))
            case .cjk:
                for word in tokenizeWords(token) {
                    let trimmedWord = trimSuffixStopwords(word)
                    guard !trimmedWord.isEmpty else { continue }
                    if trimmedWord != word && trimmedWord.count >= 4 {
                        for sub in tokenizeWords(trimmedWord) {
                            appendTerm(.cjk(text: sub, bigrams: makeBigrams(sub)))
                        }
                    } else {
                        appendTerm(.cjk(text: trimmedWord, bigrams: makeBigrams(trimmedWord)))
                    }
                }
            case .unicode:
                for word in tokenizeWords(token) where !word.isEmpty {
                    appendTerm(.word(whole: word, parts: []))
                }
            case .separator:
                break
            }
        }

        for scalar in norm.unicodeScalars {
            let kind: ScriptKind
            if isASCIITokenScalar(scalar) {
                kind = .ascii
            } else if isCJKOrKanaOrHangul(scalar) {
                kind = .cjk
            } else if isUnicodeWordScalar(scalar) {
                kind = .unicode
            } else {
                kind = .separator
            }
            if kind != currentKind {
                flush()
                currentKind = kind
            }
            if kind != .separator {
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }

    private static func extractWordSet(from norm: String) -> Set<String> {
        var words: Set<String> = []
        enum ScriptKind { case ascii, unicode, separator }
        var current = ""
        var currentKind: ScriptKind = .separator

        func flush() {
            guard !current.isEmpty else { return }
            let token = current
            current = ""
            switch currentKind {
            case .ascii:
                words.insert(token)
                for part in splitAlphaDigitParts(token) {
                    words.insert(part)
                }
            case .unicode:
                for word in tokenizeWords(token) where !word.isEmpty {
                    words.insert(word)
                }
            case .separator:
                break
            }
        }

        for scalar in norm.unicodeScalars {
            let kind: ScriptKind
            if isASCIITokenScalar(scalar) {
                kind = .ascii
            } else if !isCJKOrKanaOrHangul(scalar) && isUnicodeWordScalar(scalar) {
                kind = .unicode
            } else {
                kind = .separator
            }
            if kind != currentKind {
                flush()
                currentKind = kind
            }
            if kind != .separator {
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return words
    }

    private static func splitAlphaDigitParts(_ token: String) -> [String] {
        var parts: [String] = []
        var run = ""
        var prevIsDigit: Bool?
        for ch in token {
            let isDigit = ch.isNumber
            if let prev = prevIsDigit, prev != isDigit {
                if !run.isEmpty { parts.append(run) }
                run = String(ch)
            } else {
                run.append(ch)
            }
            prevIsDigit = isDigit
        }
        if !run.isEmpty { parts.append(run) }
        guard parts.count >= 2 else { return [] }
        let hasLongAlpha = parts.contains { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
        return hasLongAlpha ? parts : []
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let tokens = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }.filter { !$0.isEmpty }
        return tokens.isEmpty ? [text] : tokens
    }

    private static func trimSuffixStopwords(_ word: String) -> String {
        guard word.count >= 5 else { return word }
        for suffix in suffixStopwords where word.hasSuffix(suffix) && word.count > suffix.count {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func makeBigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [text] }
        var out: [String] = []
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.append(String([chars[i], chars[i + 1]]))
        }
        return out
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

    private func currentLoader() -> (@Sendable () async -> WebSearchConfig)? {
        lock.lock()
        defer { lock.unlock() }
        return loader
    }

    func load() async -> WebSearchConfig {
        let current = currentLoader()
        return await current?() ?? WebSearchConfig()
    }
}

/// Searches the web using the configured primary provider (default: built-in Bing / DuckDuckGo) and ordered fallback chain.
public struct WebSearchTool: AgentTool {
    public var hasSideEffects: Bool { false }

    public struct ProbeResult: Sendable {
        public var ok: Bool
        public var source: String
        public var count: Int
        public var detail: String
    }

    private enum BuiltinOutcome {
        case success(source: String, results: [WebText.Result])
        case exhausted(failures: [String], hadUnrelated: Bool, hadHardError: Bool)
    }

    private static let configBox = SearchConfigBox()

    /// Registers a global async config loader (called by the app at launch so every `WebSearchTool()` picks up live settings).
    public static func setConfigLoader(_ loader: (@Sendable () async -> WebSearchConfig)?) {
        configBox.set(loader)
    }

    private let loadConfig: @Sendable () async -> WebSearchConfig
    private let sendJSON: @Sendable (URLRequest) async throws -> (status: Int, data: Data)
    private let sendSearXNG: @Sendable (URLRequest) async throws -> (status: Int, data: Data)
    private let fetchHTML: @Sendable (URL) async throws -> String

    public init() {
        loadConfig = { await Self.configBox.load() }
        sendJSON = { try await WebFetch.json($0) }
        sendSearXNG = { try await WebFetch.searxngJSON($0) }
        fetchHTML = { url in
            let page = try await WebFetch.get(url, timeout: 12)
            return WebText.decode(page.data, encodingName: page.encoding)
        }
    }

    init(fetchHTML: @escaping @Sendable (URL) async throws -> String) {
        loadConfig = { WebSearchConfig(primary: .builtin, apiKey: nil, fallbackToBuiltin: true) }
        sendJSON = { _ in throw ProviderError("测试环境未配置 JSON 搜索。") }
        sendSearXNG = { _ in throw ProviderError("测试环境未配置 JSON 搜索。") }
        self.fetchHTML = fetchHTML
    }

    init(
        config: WebSearchConfig,
        sendJSON: @escaping @Sendable (URLRequest) async throws -> (status: Int, data: Data),
        fetchHTML: @escaping @Sendable (URL) async throws -> String = { _ in "" }
    ) {
        loadConfig = { config }
        self.sendJSON = sendJSON
        self.sendSearXNG = sendJSON
        self.fetchHTML = fetchHTML
    }

    /// Runs a live single-provider probe (no fallback) for the Settings page "试搜一下" check.
    public static func probe(query: String = "Swift", config: WebSearchConfig) async -> ProbeResult {
        var mutableDirect = config
        mutableDirect.fallbackToBuiltin = false
        mutableDirect.fallbackOrder = []
        let direct = mutableDirect
        let tool = WebSearchTool(
            config: direct,
            sendJSON: { request in
                if direct.primary == .searxng {
                    return try await WebFetch.searxngJSON(request)
                }
                return try await WebFetch.json(request)
            },
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
        var hadHardError = false
        var hadUnrelatedBuiltinResults = false

        for provider in config.searchChain {
            try Task.checkCancellation()
            if provider == .builtin {
                switch try await runBuiltin(query: query) {
                case let .success(source, results):
                    return format(results: results, source: source)
                case let .exhausted(builtinFailures, hadUnrelated, builtinHardError):
                    failures.append(contentsOf: builtinFailures)
                    hadUnrelatedBuiltinResults = hadUnrelatedBuiltinResults || hadUnrelated
                    hadHardError = hadHardError || builtinHardError
                }
            } else {
                do {
                    let key = config.key(for: provider)
                    let request = try WebSearchAPI.buildRequest(
                        provider: provider,
                        query: query,
                        apiKey: key,
                        searxngURL: config.searxngURL,
                        maxResults: 8
                    )
                    let response: (status: Int, data: Data)
                    if provider == .searxng {
                        response = try await sendSearXNG(request)
                    } else {
                        response = try await sendJSON(request)
                    }
                    let results = try WebSearchAPI.parseResponse(
                        provider: provider,
                        status: response.status,
                        data: response.data
                    )
                    if !results.isEmpty {
                        let hasKey = !(key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        let sourceName = (provider == .anysearch && !hasKey) ? "AnySearch（免费通道）" : provider.shortName
                        return format(results: results, source: sourceName)
                    }
                    failures.append("\(provider.shortName) 未返回结果")
                } catch {
                    try Task.checkCancellation()
                    hadHardError = true
                    failures.append(error.localizedDescription)
                }
            }
        }

        if hadUnrelatedBuiltinResults && !hadHardError {
            return ToolOutput("没有找到与搜索词足够相关的结果。可以补上地点、名称或日期再搜。")
        }
        if hadHardError {
            return ToolOutput("搜索失败：\(failures.joined(separator: "；"))", isError: true)
        }
        return ToolOutput(failures.isEmpty ? "没有搜到结果。" : "没有搜到结果（\(failures.joined(separator: "；"))）。")
    }

    private func runBuiltin(query: String) async throws -> BuiltinOutcome {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let relevance = SearchRelevance(query: query)
        var failures: [String] = []
        var hadUnrelatedResults = false
        var hadHardError = false
        for (source, address, parse) in [
            ("Bing 国际站", "https://www.bing.com/search?q=\(encoded)&setlang=zh-Hans", WebText.bingResults),
            ("Bing 中国站", "https://cn.bing.com/search?q=\(encoded)", WebText.bingResults),
            ("DuckDuckGo", "https://html.duckduckgo.com/html/?q=\(encoded)", WebText.duckResults),
        ] {
            guard let url = URL(string: address) else { continue }
            do {
                try Task.checkCancellation()
                let raw = parse(try await fetchHTML(url))
                var scored: [(index: Int, score: Double, result: WebText.Result)] = []
                for (index, item) in raw.enumerated() {
                    if let s = relevance.score(item) {
                        scored.append((index: index, score: s, result: item))
                    }
                }
                scored.sort { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.index < rhs.index
                }
                let results = scored.map(\.result)
                guard !results.isEmpty else {
                    hadUnrelatedResults = hadUnrelatedResults || !raw.isEmpty
                    continue
                }
                return .success(source: source, results: results)
            } catch {
                try Task.checkCancellation()
                hadHardError = true
                failures.append(error.localizedDescription)
            }
        }
        return .exhausted(failures: failures, hadUnrelated: hadUnrelatedResults, hadHardError: hadHardError)
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
    /// Remote attachments have no implicit LAN grant, even if the web tool has one.
    public static func allowsRemoteImage(_ url: URL) async -> Bool {
        guard classifyLiteral(url) == .publicAddress else { return false }
        return await PrivateNetworkPolicy.shared.evaluateAsync(url: url, allowAuthorizedPrivate: false).allowed
    }

    public static let refusal = "这是本机或局域网里的地址，网页工具不去这种地方，只开公网网址。真要看，请用户自己在远游的地址栏里打开。"

    public static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return true }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan")
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
        guard var host = url.host?.lowercased(), !host.isEmpty else { return true }
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
        if b[0] >= 224 { return true }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        case (198, 18...19): return true
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
    public var hasSideEffects: Bool { false }

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
        let initialEval = await PrivateNetworkPolicy.shared.evaluateAsync(url: url, action: .read, allowAuthorizedPrivate: true)
        if !initialEval.allowed {
            let msg = (initialEval.diagnostic == .fakeIPPlaceholder || initialEval.diagnostic == .mixedDNSAnomaly || initialEval.diagnostic == .scopeEscalationBlocked)
                ? (initialEval.reason ?? LocalAddress.refusal)
                : LocalAddress.refusal
            return ToolOutput(msg, isError: true)
        }
        let page = try await fetch(url)
        // A public address can send us on to an unauthorized local/private one; what came back from there is not handed over.
        let finalEval = await PrivateNetworkPolicy.shared.evaluateAsync(url: page.url, action: .read, allowAuthorizedPrivate: true)
        if !finalEval.allowed {
            let msg = (finalEval.diagnostic == .fakeIPPlaceholder || finalEval.diagnostic == .mixedDNSAnomaly || finalEval.diagnostic == .scopeEscalationBlocked)
                ? (finalEval.reason ?? LocalAddress.refusal)
                : LocalAddress.refusal
            return ToolOutput(msg, isError: true)
        }
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
