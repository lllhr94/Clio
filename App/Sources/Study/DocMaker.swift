import AgentKit
import Foundation
import Prose
import UIKit

/// Turns what a companion wrote (Markdown) into a file people can send: a PDF, a Word file, a web page,
/// or a table as CSV. Saved in 书案/文稿, so it can be opened, shared or printed from there.
enum DocMaker {
    enum Format: String, CaseIterable {
        case pdf, word, html, csv
        var ext: String { self == .word ? "doc" : rawValue }
    }

    static func tool() -> AgentTool {
        DeskTool(name: "make_document", description: """
        把你写好的内容做成文件存进书案/文稿：pdf（排好版的 PDF）、word（Word 能直接打开的 .doc）、html（网页）、csv（表格，取内容里第一张 Markdown 表格）。
        内容用 Markdown 写：标题、段落、列表、表格、代码都行。用户要「做成文档 / 导出 PDF / 给我一个 Word / 做成表格」时用。做好后告诉用户文件名。
        """, parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "文件名（不带扩展名），也是文档标题"],
                "format": ["type": "string", "enum": ["pdf", "word", "html", "csv"]],
                "markdown": ["type": "string", "description": "全文，Markdown"],
            ],
            "required": ["title", "format", "markdown"],
        ], label: { arguments in
            let format = Format(rawValue: arguments["format"]?.string ?? "") ?? .pdf
            return Words.t("书案：写 文稿/\(name(arguments["title"]?.string)).\(format.ext)")
        }) { arguments in
            let format = Format(rawValue: arguments["format"]?.string ?? "") ?? .pdf
            let title = name(arguments["title"]?.string)
            let markdown = arguments["markdown"]?.string ?? ""
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ToolOutput("内容是空的。", isError: true) }
            let folder = Workspace.root.appendingPathComponent("文稿", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(title).\(format.ext)")
            let data: Data
            switch format {
            case .pdf: data = await pdf(html(markdown, title: title))
            case .word: data = Data(word(markdown, title: title).utf8)
            case .html: data = Data(html(markdown, title: title).utf8)
            case .csv:
                guard let csv = csv(markdown) else { return ToolOutput("内容里没有 Markdown 表格，做不成 CSV。", isError: true) }
                // With a byte-order mark, so Excel and Numbers read the Chinese right.
                data = Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)
            }
            try data.write(to: file, options: .atomic)
            return ToolOutput("做好了：书案/文稿/\(file.lastPathComponent)（\(Workspace.size(data.count))）")
        }
    }

    private static func name(_ raw: String?) -> String {
        let cleaned = (raw ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "文稿" : String(cleaned.prefix(60))
    }

    // MARK: HTML

    static func html(_ markdown: String, title: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11.5pt; line-height: 1.65; color: #222; max-width: 720px; margin: 0 auto; }
        h1 { font-size: 20pt; margin: 0 0 12pt; } h2 { font-size: 15pt; margin: 18pt 0 6pt; } h3 { font-size: 12.5pt; margin: 14pt 0 4pt; }
        table { border-collapse: collapse; width: 100%; margin: 8pt 0; } th, td { border: 1px solid #bbb; padding: 4pt 6pt; text-align: left; vertical-align: top; } th { background: #f2efe8; }
        pre { background: #f5f3ee; padding: 8pt; white-space: pre-wrap; font-size: 9.5pt; } code { font-family: Menlo, monospace; }
        blockquote { border-left: 3px solid #ccc; margin: 8pt 0; padding-left: 10pt; color: #555; } hr { border: none; border-top: 1px solid #ccc; }
        </style></head><body>
        \(body(Prose.parse(markdown)))
        </body></html>
        """
    }

    /// Word opens a web page saved as .doc, keeping headings, tables and lists.
    static func word(_ markdown: String, title: String) -> String {
        html(markdown, title: title).replacingOccurrences(of: "<html lang=\"zh-CN\">", with: "<html xmlns:o=\"urn:schemas-microsoft-com:office:office\" xmlns:w=\"urn:schemas-microsoft-com:office:word\" lang=\"zh-CN\">")
    }

    private static func body(_ blocks: [Prose.Block]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(let level, let text): return "<h\(min(6, max(1, level)))>\(inline(text))</h\(min(6, max(1, level)))>"
            case .paragraph(let text): return "<p>\(inline(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            case .list(let items):
                let ordered = items.first?.number != nil
                let rows = items.map { item -> String in
                    let box = item.checked.map { $0 ? "☑ " : "☐ " } ?? ""
                    return "<li style=\"margin-left:\(item.depth * 18)px\">\(box)\(inline(item.text))</li>"
                }.joined()
                return ordered ? "<ol>\(rows)</ol>" : "<ul>\(rows)</ul>"
            case .quote(let inner): return "<blockquote>\(body(inner))</blockquote>"
            case .code(_, let text, _): return "<pre><code>\(escape(text))</code></pre>"
            case .table(let table):
                let head = table.header.map { "<th>\(inline($0))</th>" }.joined()
                let rows = table.rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                return "<table><thead><tr>\(head)</tr></thead><tbody>\(rows)</tbody></table>"
            case .math(let text): return "<pre>\(escape(text))</pre>"
            case .rule: return "<hr>"
            }
        }.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Bold, italics, code and links.
    private static func inline(_ text: String) -> String {
        var out = escape(text)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<b>$1</b>"),
            ("(?<![*\\w])\\*([^*\\n]+)\\*(?!\\w)", "<i>$1</i>"),
            ("~~([^~]+)~~", "<s>$1</s>"),
            ("\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    // MARK: PDF

    @MainActor
    static func pdf(_ html: String) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 50, dy: 56)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    // MARK: CSV

    static func csv(_ markdown: String) -> String? {
        for block in Prose.parse(markdown) {
            guard case .table(let table) = block else { continue }
            func cell(_ text: String) -> String {
                let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                return plain.contains(where: { ",\"\n".contains($0) }) ? "\"" + plain.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : plain
            }
            return ([table.header] + table.rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n")
        }
        return nil
    }
}
