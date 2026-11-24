import Foundation

public struct MemoryMirrorBot: Equatable, Sendable {
    public var name: String
    public var role: String?
    public var isMain: Bool

    public init(name: String, role: String? = nil, isMain: Bool = false) {
        self.name = name
        self.role = role
        self.isMain = isMain
    }
}

/// Deterministic, secret-redacting Markdown mirror generator for `书案/档案.md` and `书案/镇纸.md`.
public enum MemoryMarkdownRenderer {
    public static let startMarker = "<!-- clio:memory-mirror:start -->"
    public static let endMarker = "<!-- clio:memory-mirror:end -->"

    public static func renderZhenzhi(
        records: [MemoryRecord],
        secrets: [String] = [],
        timeZone: TimeZone = .current
    ) -> String {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let pinned = records
            .filter { $0.deletedAtMs == nil && $0.layer == .pinned }
            .sorted { lhs, rhs in
                if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                return lhs.id < rhs.id
            }

        let updatedLabel = formatLatestDate(for: pinned, timeZone: timeZone)
        var lines: [String] = [
            startMarker,
            "# 镇纸",
            "",
            "> Clio 自动同步的核心设定（常驻置顶，不随对话长度下沉）。请勿在此写入密钥或密码。",
            "",
            "- 更新日期：\(updatedLabel)",
            "- 置顶条目：\(pinned.count) 条",
            "",
        ]
        if pinned.isEmpty {
            lines.append("（暂无置顶记忆。在记忆中设为置顶的核心设定会常驻在这里。）")
        } else {
            for item in pinned {
                lines.append(formatBullet(item, secrets: orderedSecrets))
            }
        }
        lines.append(endMarker)
        let raw = lines.joined(separator: "\n")
        return redact(raw, orderedSecrets: orderedSecrets)
    }

    public static func renderDangan(
        records: [MemoryRecord],
        bots: [MemoryMirrorBot] = [],
        secrets: [String] = [],
        timeZone: TimeZone = .current
    ) -> String {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let active = records
            .filter { $0.deletedAtMs == nil }
            .sorted { lhs, rhs in
                if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
                return lhs.id < rhs.id
            }

        let pinned = active.filter { $0.layer == .pinned }
        let surface = active.filter { $0.layer == .surface }
        let deep = active.filter { $0.layer == .deep }
        let archivedCount = active.filter { $0.layer == .archived }.count

        let updatedLabel = formatLatestDate(for: active, timeZone: timeZone)
        var summaryParts = [
            "镇纸 \(pinned.count) 条",
            "常记 \(surface.count) 条",
            "旧事 \(deep.count) 条",
        ]
        if archivedCount > 0 {
            summaryParts.append("归档 \(archivedCount) 条")
        }

        var lines: [String] = [
            startMarker,
            "# 档案",
            "",
            "> Clio 自动同步的用户档案与记忆概览。下方标记区域之外的手写笔记不会被覆盖；请勿在此写入密钥或密码。",
            "",
            "- 更新日期：\(updatedLabel)",
            "- 概览：\(summaryParts.joined(separator: " · "))",
        ]

        if !bots.isEmpty {
            lines.append("")
            lines.append("## 助手设定")
            lines.append("")
            for bot in bots {
                let safeName = redact(bot.name.trimmingCharacters(in: .whitespacesAndNewlines), orderedSecrets: orderedSecrets)
                guard !safeName.isEmpty else { continue }
                let safeRole = bot.role
                    .map { redact($0.trimmingCharacters(in: .whitespacesAndNewlines), orderedSecrets: orderedSecrets) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                var suffix: [String] = []
                if bot.isMain { suffix.append("主") }
                if let safeRole { suffix.append(safeRole) }
                if suffix.isEmpty {
                    lines.append("- \(safeName)")
                } else {
                    lines.append("- \(safeName)（\(suffix.joined(separator: " · "))）")
                }
            }
        }

        lines.append("")
        lines.append("## 核心设定（镇纸）")
        lines.append("")
        if pinned.isEmpty {
            lines.append("（暂无置顶设定）")
        } else {
            for item in pinned {
                lines.append(formatBullet(item, secrets: orderedSecrets))
            }
        }

        lines.append("")
        lines.append("## 常记（当前对话注入）")
        lines.append("")
        if surface.isEmpty {
            lines.append("（暂无常记条目）")
        } else {
            for item in surface {
                lines.append(formatBullet(item, secrets: orderedSecrets))
            }
        }

        lines.append("")
        lines.append("## 旧事（按需召回）")
        lines.append("")
        if deep.isEmpty {
            lines.append("（暂无旧事条目）")
        } else {
            for item in deep {
                lines.append(formatBullet(item, secrets: orderedSecrets))
            }
        }

        lines.append(endMarker)
        let raw = lines.joined(separator: "\n")
        return redact(raw, orderedSecrets: orderedSecrets)
    }

    /// Merges `managedBlock` into existing file content without clobbering user manual notes outside the markers.
    public static func mergeManagedSection(_ managedBlock: String, into existing: String?) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return managedBlock + "\n"
        }
        if let startRange = existing.range(of: startMarker),
           let endRange = existing.range(of: endMarker, range: startRange.upperBound..<existing.endIndex) {
            var updated = existing
            updated.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: managedBlock)
            if !updated.hasSuffix("\n") { updated.append("\n") }
            return updated
        }
        let trimmedExisting = existing.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
        return trimmedExisting + "\n\n---\n\n" + managedBlock + "\n"
    }

    public static func shouldWrite(merged: String, existing: String?) -> Bool {
        merged != existing
    }

    private static func formatBullet(_ record: MemoryRecord, secrets: [String]) -> String {
        let safeText = redact(record.text, orderedSecrets: secrets)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        if !record.kind.isEmpty && record.kind != "fact" {
            tags.append(redact(record.kind, orderedSecrets: secrets))
        }
        if !record.topic.isEmpty {
            tags.append(redact(record.topic, orderedSecrets: secrets))
        }
        if tags.isEmpty {
            return "- \(safeText)"
        }
        return "- [\(tags.joined(separator: " · "))] \(safeText)"
    }

    private static func formatLatestDate(for records: [MemoryRecord], timeZone: TimeZone) -> String {
        guard let latestMs = records.map({ max($0.updatedAtMs, $0.createdAtMs) }).max(), latestMs > 0 else {
            return "暂无"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: latestMs / 1000))
    }

    private static func redact(_ text: String, orderedSecrets: [String]) -> String {
        orderedSecrets.isEmpty ? text : MemorySafety.redactSecrets(text, secrets: orderedSecrets)
    }
}
