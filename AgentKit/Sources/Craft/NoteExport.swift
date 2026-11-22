import Foundation

public enum NoteExportError: LocalizedError, Equatable {
    case nameExhausted

    public var errorDescription: String? {
        switch self {
        case .nameExhausted:
            return "同名笔记太多了，请换一个文件名再保存。"
        }
    }
}

/// Pure formatting and atomic exclusive-create helpers for saving replies as Markdown notes.
public enum NoteExport {
    /// Double-quotes a string as a valid single-line YAML scalar (safe for colons, `#`, quotes, backslashes, and newlines).
    public static func yamlString(_ raw: String) -> String {
        var out = "\""
        out.reserveCapacity(raw.count + 2)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out.append(String(format: "\\u%04X", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }

    /// Formats a Markdown note with optional YAML front matter (stable ISO-8601 date + escaped `from` string).
    public static func markdown(
        body: String,
        question: String?,
        sender: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        includeHeader: Bool
    ) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeHeader else { return trimmedBody + "\n" }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)

        var lines: [String] = [
            "---",
            "date: \(stamp)",
            "from: \(yamlString(sender))",
            "---",
            "",
        ]
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let quoted = q.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            lines.append(quoted)
            lines.append("")
        }
        lines.append(trimmedBody)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Atomically creates a brand-new file using `.withoutOverwriting` (`O_CREAT | O_EXCL`).
    /// Retries with ` 2`, ` 3`, ... on collision and throws `NoteExportError.nameExhausted` rather than overwriting an existing file.
    @discardableResult
    public static func writeUniqueNewFile(
        in directory: URL,
        fileName: String,
        data: Data,
        maxAttempts: Int = 99,
        validateTarget: ((URL) throws -> Void)? = nil
    ) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        let limit = max(1, maxAttempts)

        for attempt in 1...limit {
            let candidateName: String
            if attempt == 1 {
                candidateName = fileName
            } else if ext.isEmpty {
                candidateName = "\(stem) \(attempt)"
            } else {
                candidateName = "\(stem) \(attempt).\(ext)"
            }
            let target = directory.appendingPathComponent(candidateName)
            try validateTarget?(target)
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return candidateName
            } catch {
                if isAlreadyExistsError(error) { continue }
                throw error
            }
        }
        throw NoteExportError.nameExhausted
    }

    private static func isAlreadyExistsError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteFileExists.rawValue {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EEXIST)
        }
        return false
    }
}
