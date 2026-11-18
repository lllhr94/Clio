import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// The words in a PDF, page by page.
public enum PDFText {
    public struct Reading: Equatable, Sendable {
        public var title: String?
        /// Pages in the whole file.
        public var pages: Int
        /// The pages read, 1-based, with their words (empty for a page that is only a picture).
        public var read: [Page]

        public struct Page: Equatable, Sendable {
            public var number: Int
            public var text: String
        }

        /// Pages read that had no words: scans or pictures.
        public var blank: [Int] { read.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.number) }

        /// What a model is given: a heading, then each page under its number, cut at `limit` characters.
        public func shown(limit: Int) -> String {
            guard let first = read.first, let last = read.last else { return "（这份 PDF 共 \(pages) 页，这一段没有页。）" }
            var heading = (title.map { "《\($0)》" } ?? "这份 PDF") + "共 \(pages) 页"
            heading += first.number == last.number ? "，这是第 \(first.number) 页。" : "，这是第 \(first.number)–\(last.number) 页。"
            var body = ""
            var shownUntil = first.number - 1
            for page in read {
                let words = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let part = "\n\n—— 第 \(page.number) 页 ——\n" + (words.isEmpty ? "（这一页没有文字，可能是扫描件或图片）" : words)
                if body.count + part.count > limit, !body.isEmpty { break }
                body += part.count > limit ? String(part.prefix(limit)) + "……" : part
                shownUntil = page.number
            }
            if shownUntil < pages { body += "\n\n（后面还有：从第 \(shownUntil + 1) 页接着读。）" }
            return heading + body
        }
    }

    /// Reads `count` pages starting at `from` (1-based). Nil when the data is not a PDF this device can open.
    public static func read(_ data: Data, from: Int = 1, count: Int = 20) -> Reading? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else { return nil }
        if document.isLocked, !document.unlock(withPassword: "") { return Reading(title: nil, pages: document.pageCount, read: []) }
        let total = document.pageCount
        let start = max(1, min(from, max(total, 1)))
        let end = min(total, start + max(1, count) - 1)
        var pages: [Reading.Page] = []
        if total > 0 {
            for number in start...end {
                pages.append(Reading.Page(number: number, text: document.page(at: number - 1)?.string ?? ""))
            }
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(title: title?.isEmpty == false ? title : nil, pages: total, read: pages)
        #else
        return nil
        #endif
    }

    /// The whole text, for searching. Nil when it is not a PDF.
    public static func all(_ data: Data, maxPages: Int = 400) -> String? {
        read(data, from: 1, count: maxPages).map { reading in
            reading.read.map { "[第 \($0.number) 页]\n\($0.text)" }.joined(separator: "\n\n")
        }
    }

    /// All the words of a PDF file, each page under its number; for keeping beside it as text.
    public static func extract(_ url: URL, limit: Int = 400_000) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        var out = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            out += "\n\n——第 \(index + 1) 页——\n" + text
            if out.count > limit { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }

    /// The bytes start like a PDF.
    public static func looksLike(_ data: Data) -> Bool { data.prefix(5) == Data("%PDF-".utf8) }
}
