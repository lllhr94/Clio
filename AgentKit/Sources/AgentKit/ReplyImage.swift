import Foundation

/// An image returned by the replying model, before the caller chooses where to store it.
public enum ReplyImage: Hashable, Sendable {
    case embedded(ImagePart)
    case remote(URL)

    static let dataPrefix = "data:image/"
    static let maxEncodedSize = 32 * 1024 * 1024

    static func source(_ value: String) -> ReplyImage? {
        if value.hasPrefix(dataPrefix) {
            guard let comma = value.firstIndex(of: ","),
                  value[..<comma].hasSuffix(";base64") else { return nil }
            let type = value.dropFirst(5)[..<comma].dropLast(";base64".count)
            return base64(value[value.index(after: comma)...], mediaType: String(type))
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return .remote(url)
    }

    static func base64(_ bytes: Substring, mediaType: String) -> ReplyImage? {
        guard mediaType.hasPrefix("image/"), bytes.utf8.count <= maxEncodedSize,
              let data = Data(base64Encoded: String(bytes)), !data.isEmpty else { return nil }
        return .embedded(ImagePart(mediaType: mediaType, data: data))
    }
}

/// Extracts bare or Markdown-wrapped data URLs without putting their bytes into the visible text stream.
struct ReplyImageText {
    private static let start = try! NSRegularExpression(pattern: #"(!\[[^\]\n\r]{0,100}\]\()?data:image/"#)
    private var pending = ""
    private var encoded: String?
    private var tooLarge = false
    private var wrapped = false

    mutating func feed(_ part: String) -> [StreamEvent] {
        var text = pending + part
        pending = ""
        var out: [StreamEvent] = []
        while !text.isEmpty {
            if encoded != nil {
                let end = text.utf8.firstIndex { byte in
                    switch byte {
                    case 43, 44, 45, 46, 47, 48...57, 59, 61, 65...90, 95, 97...122: return false
                    default: return true
                    }
                } ?? text.endIndex
                if !tooLarge {
                    if (encoded?.utf8.count ?? 0) + text.utf8.distance(from: text.startIndex, to: end) > ReplyImage.maxEncodedSize {
                        tooLarge = true
                        encoded = ""
                    } else {
                        encoded?.append(contentsOf: text[..<end])
                    }
                }
                guard end != text.endIndex else { break }
                if let event = finishImage() { out.append(event) }
                let start = wrapped && text[end] == ")" ? text.index(after: end) : end
                wrapped = false
                text = String(text[start...])
                continue
            }
            if let match = Self.start.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                if range.lowerBound != text.startIndex { out.append(.text(String(text[..<range.lowerBound]))) }
                wrapped = match.range(at: 1).location != NSNotFound
                encoded = ReplyImage.dataPrefix
                text = String(text[range.upperBound...])
                continue
            }
            let suffix = Self.possiblePrefix(in: text)
            if !suffix.isEmpty { pending = suffix }
            let visible = text.dropLast(suffix.count)
            if !visible.isEmpty { out.append(.text(String(visible))) }
            break
        }
        return out
    }

    mutating func flush() -> [StreamEvent] {
        var out: [StreamEvent] = []
        if let event = finishImage() { out.append(event) }
        if !pending.isEmpty { out.append(.text(pending)) }
        pending = ""
        wrapped = false
        return out
    }

    private mutating func finishImage() -> StreamEvent? {
        defer { encoded = nil; tooLarge = false }
        guard let encoded, !tooLarge, let image = ReplyImage.source(encoded) else { return nil }
        return .image(image)
    }

    private static func possiblePrefix(in text: String) -> String {
        let tail = text.suffix(ReplyImage.dataPrefix.count + 104)
        if let mark = tail.range(of: "![", options: .backwards) {
            let rest = tail[mark.upperBound...]
            if let close = rest.firstIndex(of: "]") {
                let after = rest[rest.index(after: close)...]
                if ("(" + ReplyImage.dataPrefix).hasPrefix(after) { return String(tail[mark.lowerBound...]) }
            } else if rest.count <= 100 && !rest.contains(where: \.isNewline) {
                return String(tail[mark.lowerBound...])
            }
        }
        let prefix = ReplyImage.dataPrefix
        for count in stride(from: min(tail.count, prefix.count - 1), through: 1, by: -1) {
            let suffix = tail.suffix(count)
            if prefix.hasPrefix(suffix) { return String(suffix) }
        }
        return text.hasSuffix("!") ? "!" : ""
    }
}
