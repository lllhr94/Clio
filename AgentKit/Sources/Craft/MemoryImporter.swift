import Foundation

/// A single parsed, sanitized candidate memory awaiting user confirmation before commit.
public struct MemoryImportCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var kind: String
    public var topic: String
    public var selected: Bool
    public var targetLayer: MemoryLayer

    public init(
        id: String = UUID().uuidString,
        text: String,
        kind: String = "fact",
        topic: String = "",
        selected: Bool = true,
        targetLayer: MemoryLayer = .surface
    ) {
        self.id = id
        self.text = text
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = cleanKind.isEmpty ? "fact" : cleanKind
        self.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selected = selected
        self.targetLayer = targetLayer
    }
}

/// A parsed line skipped during import preview, along with a redacted preview and Chinese reason.
public struct MemoryImportSkippedItem: Identifiable, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case duplicateExisting
        case duplicateInBatch
        case retracted
        case secretDetected
        case tooLong

        public var localizedReason: String {
            switch self {
            case .duplicateExisting: return "已有相同记忆"
            case .duplicateInBatch: return "与本次导入条目重复"
            case .retracted: return "此前已删除或撤回"
            case .secretDetected: return "疑似包含密钥或敏感凭据"
            case .tooLong: return "内容过长（超过 450 字节）"
            }
        }
    }

    public var id: String
    public var text: String
    public var reason: Reason

    public var reasonText: String { reason.localizedReason }

    public init(id: String = UUID().uuidString, text: String, reason: Reason) {
        self.id = id
        self.text = text
        self.reason = reason
    }
}

/// Preview result produced by `MemoryImporter.parse` for user review.
public struct MemoryImportPreview: Equatable, Sendable {
    public var candidates: [MemoryImportCandidate]
    public var skipped: [MemoryImportSkippedItem]

    public var selectedCount: Int {
        candidates.reduce(0) { $0 + ($1.selected ? 1 : 0) }
    }

    public init(candidates: [MemoryImportCandidate] = [], skipped: [MemoryImportSkippedItem] = []) {
        self.candidates = candidates
        self.skipped = skipped
    }
}

/// Parses pasted notes and `.txt` / `.md` memory exports (including Clio mirrors, ChatGPT, and Claude notes)
/// into sanitized, deduplicated, secret-safe `MemoryImportCandidate` items.
public enum MemoryImporter {
    public static let redactedSecretPreview = "〔隐去〕已拦截疑似包含密钥或敏感凭据的条目"

    private static let maxFactBytes = 450
    private static let maxTopicLength = 40

    private static let pemBeginPattern = #"-----BEGIN [A-Z0-9 ]*-----"#
    private static let pemEndPattern = #"-----END [A-Z0-9 ]*-----"#

    private static let tokenSecretPatterns: [String] = [
        #"\bsk-(?:proj-|ant-api\d*-|live-|test-)?[A-Za-z0-9_-]{16,}\b"#,
        #"\bsk-ant-[A-Za-z0-9_-]{12,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,
        #"\bAIza[0-9A-Za-z_-]{20,}\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#,
        #"-----BEGIN [A-Z0-9 ]*-----"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#,
    ]

    private static let assignmentSecretPattern =
        #"(?i)(?:api[_-]?key|secret[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|private[_-]?key|client[_-]?secret|password|passwd|密码|密钥|口令|令牌)["']?\s*[:=：]\s*([^\r\n]+)"#

    private static let harmlessSecretPlaceholders: Set<String> = [
        "无", "暂无", "未知", "保密", "已设置", "未设置", "不保存", "不记住", "none", "n/a", "na", "unset", "redacted",
    ]

    private static let knownKinds: Set<String> = [
        "fact", "preference", "project", "rule", "goal", "experience", "note", "profile", "habit", "decision",
    ]

    private static let kindAliases: [String: String] = [
        "偏好": "preference",
        "喜好": "preference",
        "习惯": "preference",
        "风格": "preference",
        "preference": "preference",
        "preferences": "preference",
        "项目": "project",
        "工程": "project",
        "project": "project",
        "projects": "project",
        "规则": "rule",
        "原则": "rule",
        "约定": "rule",
        "指令": "rule",
        "rule": "rule",
        "rules": "rule",
        "目标": "goal",
        "计划": "goal",
        "goal": "goal",
        "goals": "goal",
        "经历": "experience",
        "背景": "experience",
        "experience": "experience",
        "事实": "fact",
        "资料": "fact",
        "fact": "fact",
        "facts": "fact",
        "笔记": "note",
        "note": "note",
    ]

    /// Parses raw pasted text or `.txt`/`.md` content into reviewable candidates and skipped items.
    public static func parse(
        _ rawText: String,
        defaultLayer: MemoryLayer = .surface,
        existingTexts: [String] = [],
        suppressedHashes: Set<String> = [],
        secrets: [String] = [],
        isRetracted: ((String) -> Bool)? = nil
    ) -> MemoryImportPreview {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let normalized = normalizeInputLines(rawText)
        let lines = stripLeadingFrontmatter(normalized)

        var existingKeys = Set<String>()
        for text in existingTexts {
            let key = MemorySafety.normalizedFactKey(text)
            if !key.isEmpty { existingKeys.insert(key) }
        }

        var suppressedSet = Set<String>()
        for rawHash in suppressedHashes {
            let trimmed = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if MemorySafety.isSHA256Hex(trimmed) {
                suppressedSet.insert(trimmed.lowercased())
            } else {
                let hashed = MemorySafety.retractionHash(trimmed)
                if !hashed.isEmpty { suppressedSet.insert(hashed) }
            }
        }

        var seenInBatch = Set<String>()
        var candidates: [MemoryImportCandidate] = []
        var skipped: [MemoryImportSkippedItem] = []

        var currentTopic = ""
        var currentHeadingKind: String?
        var explicitLayer: MemoryLayer?
        var explicitLayerHeadingLevel: Int?
        var inMirrorBotsSection = false
        var inPEMBlock = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if inPEMBlock {
                skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                if trimmed.range(of: pemEndPattern, options: .regularExpression) != nil {
                    inPEMBlock = false
                }
                continue
            }

            if trimmed.range(of: pemBeginPattern, options: .regularExpression) != nil {
                skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                inPEMBlock = trimmed.range(of: pemEndPattern, options: .regularExpression) == nil
                continue
            }

            if trimmed == MemoryMarkdownRenderer.endMarker {
                inMirrorBotsSection = false
                explicitLayer = nil
                explicitLayerHeadingLevel = nil
                currentTopic = ""
                currentHeadingKind = nil
                continue
            }
            if isStructuralNoise(trimmed) { continue }

            if let heading = parseMarkdownHeading(trimmed) {
                if containsSecret(heading.title, orderedSecrets: orderedSecrets) {
                    inMirrorBotsSection = false
                    currentTopic = ""
                    currentHeadingKind = nil
                    skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                    continue
                }
                if let section = parseClioLayerHeading(heading.title) {
                    inMirrorBotsSection = section.isBotsSection
                    if section.isBotsSection {
                        explicitLayer = nil
                        explicitLayerHeadingLevel = nil
                    } else if let layer = section.layer {
                        explicitLayer = layer
                        explicitLayerHeadingLevel = heading.level
                    } else {
                        explicitLayer = nil
                        explicitLayerHeadingLevel = nil
                    }
                    currentTopic = ""
                    currentHeadingKind = nil
                } else {
                    inMirrorBotsSection = false
                    if let activeLevel = explicitLayerHeadingLevel, heading.level <= activeLevel {
                        explicitLayer = nil
                        explicitLayerHeadingLevel = nil
                    }
                    currentTopic = clipTopic(heading.title)
                    currentHeadingKind = inferKind(fromHeading: currentTopic)
                }
                continue
            }

            if inMirrorBotsSection { continue }
            if isMirrorBoilerplate(trimmed) { continue }

            if let standaloneHeader = parseStandaloneSubheader(trimmed) {
                if containsSecret(standaloneHeader, orderedSecrets: orderedSecrets) {
                    currentTopic = ""
                    currentHeadingKind = nil
                    skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                    continue
                }
                currentTopic = clipTopic(standaloneHeader)
                currentHeadingKind = inferKind(fromHeading: currentTopic)
                continue
            }

            let stripped = stripListAndQuotePrefix(trimmed)
            guard !stripped.isEmpty, !isMirrorBoilerplate(stripped) else { continue }

            if containsSecret(stripped, orderedSecrets: orderedSecrets) {
                skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                continue
            }

            let parsedMeta = extractInlineMetadata(from: stripped)
            let bodyText = unwrapSimpleMarkdown(parsedMeta.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bodyText.isEmpty else { continue }

            if containsSecret(bodyText, orderedSecrets: orderedSecrets)
                || (parsedMeta.topic.map { containsSecret($0, orderedSecrets: orderedSecrets) } ?? false)
                || (parsedMeta.kind.map { containsSecret($0, orderedSecrets: orderedSecrets) } ?? false) {
                skipped.append(MemoryImportSkippedItem(text: redactedSecretPreview, reason: .secretDetected))
                continue
            }

            if bodyText.utf8.count > maxFactBytes {
                let clipped = MemorySafety.clipUTF8(bodyText, bytes: 180) + "…"
                skipped.append(MemoryImportSkippedItem(text: clipped, reason: .tooLong))
                continue
            }

            guard let sanitized = MemorySafety.sanitizeProposedFact(bodyText, secrets: orderedSecrets) else {
                continue
            }

            let key = MemorySafety.normalizedFactKey(sanitized)
            let hash = MemorySafety.retractionHash(sanitized)
            guard !key.isEmpty, !hash.isEmpty else { continue }

            if suppressedSet.contains(hash) || isRetracted?(sanitized) == true {
                skipped.append(MemoryImportSkippedItem(text: sanitized, reason: .retracted))
                continue
            }
            if existingKeys.contains(key) {
                skipped.append(MemoryImportSkippedItem(text: sanitized, reason: .duplicateExisting))
                continue
            }
            if !seenInBatch.insert(key).inserted {
                skipped.append(MemoryImportSkippedItem(text: sanitized, reason: .duplicateInBatch))
                continue
            }

            let resolvedTopic = parsedMeta.topic ?? currentTopic
            let effectiveHeadingKind = parsedMeta.topic == nil ? currentHeadingKind : nil
            let resolvedKind = parsedMeta.kind
                ?? effectiveHeadingKind
                ?? inferKind(fromText: sanitized, topic: resolvedTopic)
            let resolvedLayer = explicitLayer ?? defaultLayer

            candidates.append(
                MemoryImportCandidate(
                    text: sanitized,
                    kind: resolvedKind,
                    topic: resolvedTopic,
                    selected: true,
                    targetLayer: resolvedLayer
                )
            )
        }

        return MemoryImportPreview(candidates: candidates, skipped: skipped)
    }

    /// Returns `true` when `text` contains a Vault secret, a redaction placeholder, or a credential pattern.
    public static func looksLikeSecret(_ text: String, secrets: [String] = []) -> Bool {
        let orderedSecrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        return containsSecret(text, orderedSecrets: orderedSecrets)
    }

    // MARK: - Line Preprocessing & Structure

    private static func normalizeInputLines(_ rawText: String) -> [String] {
        var text = rawText
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func stripLeadingFrontmatter(_ lines: [String]) -> [String] {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return lines
        }
        let searchLimit = min(lines.count, 50)
        for index in 1..<searchLimit {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                return Array(lines.dropFirst(index + 1))
            }
        }
        return lines
    }

    private static func isStructuralNoise(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return true
        }
        if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") {
            return true
        }
        if trimmed.count >= 3 {
            let chars = Set(trimmed.filter { !$0.isWhitespace })
            if chars.count == 1, let only = chars.first, "-*_=~".contains(only) {
                return true
            }
        }
        return false
    }

    private static func parseMarkdownHeading(_ trimmed: String) -> (level: Int, title: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == "#" && level < 7 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard (1...6).contains(level), idx < trimmed.endIndex, trimmed[idx].isWhitespace else {
            return nil
        }
        let rawTitle = String(trimmed[idx...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = unwrapSimpleMarkdown(rawTitle)
        guard !cleanTitle.isEmpty else { return nil }
        return (level, cleanTitle)
    }

    private static func parseClioLayerHeading(_ title: String) -> (isBotsSection: Bool, layer: MemoryLayer?)? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "助手设定" {
            return (true, nil)
        }
        if normalized == "档案" {
            return (false, nil)
        }
        if normalized == "镇纸" || normalized.hasPrefix("核心设定（镇纸）") || normalized.hasPrefix("核心设定(镇纸)") {
            return (false, .pinned)
        }
        if normalized == "常记" || normalized.hasPrefix("常记（") || normalized.hasPrefix("常记(") {
            return (false, .surface)
        }
        if normalized == "旧事" || normalized.hasPrefix("旧事（") || normalized.hasPrefix("旧事(") {
            return (false, .deep)
        }
        if normalized == "归档" || normalized.hasPrefix("归档（") || normalized.hasPrefix("归档(") {
            return (false, .archived)
        }
        return nil
    }

    private static func isMirrorBoilerplate(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix(">") {
            let quoteBody = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if quoteBody.contains("Clio 自动同步") || quoteBody.contains("自动同步的用户档案")
                || quoteBody.contains("自动同步的核心设定") || quoteBody.contains("请勿在此写入密钥") {
                return true
            }
        }
        let unbulleted = stripListAndQuotePrefix(trimmed)
        if unbulleted.hasPrefix("更新日期：") || unbulleted.hasPrefix("置顶条目：") || unbulleted.hasPrefix("概览：") {
            return true
        }
        if unbulleted.hasPrefix("（暂无") && unbulleted.hasSuffix("）") {
            return true
        }
        return false
    }

    private static func parseStandaloneSubheader(_ trimmed: String) -> String? {
        let isAsteriskBullet = trimmed.hasPrefix("*") && !trimmed.hasPrefix("**")
        if trimmed.hasPrefix("-") || isAsteriskBullet || trimmed.hasPrefix("+") || trimmed.hasPrefix("•")
            || trimmed.hasPrefix("·") || trimmed.hasPrefix(">") {
            return nil
        }
        let unwrapped = unwrapSimpleMarkdown(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = unwrapped.last, last == ":" || last == "：" else { return nil }
        let stem = String(unwrapped.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem.count <= 24 else { return nil }
        if stem.contains("。") || stem.contains(",") || stem.contains("，") || stem.contains("；") {
            return nil
        }
        return stem
    }

    private static func stripListAndQuotePrefix(_ line: String) -> String {
        var working = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while working.hasPrefix(">") {
            working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Task list checkbox prefixes (`- [ ] `, `- [x] `, `* [X] `)
        if let checkboxRange = working.range(
            of: #"^(?:[-*+•·])\s*\[[ xX]\](?:\s+|$)"#,
            options: .regularExpression
        ) {
            working = String(working[checkboxRange.upperBound...])
        } else if let bulletRange = working.range(
            of: #"^(?:[-*+]\s+|[•·▪▫◦‣●○]\s*|\d{1,3}(?:[\.\)]\s+|、\s*)|[\(（]\d{1,3}[\)）]\s*)"#,
            options: .regularExpression
        ) {
            working = String(working[bulletRange.upperBound...])
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractInlineMetadata(from text: String) -> (kind: String?, topic: String?, text: String) {
        guard text.hasPrefix("["),
              let closeIdx = text.firstIndex(of: "]") else {
            return (nil, nil, text)
        }
        let afterClose = text.index(after: closeIdx)
        guard afterClose < text.endIndex else {
            return (nil, nil, text)
        }
        let remainder = String(text[afterClose...]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else {
            return (nil, nil, text)
        }
        let tagContent = String(text[text.index(after: text.startIndex)..<closeIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagContent.isEmpty, tagContent.count <= 48 else {
            return (nil, nil, text)
        }

        let parts = tagContent
            .split(whereSeparator: { $0 == "·" || $0 == "|" || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count >= 2, let mappedKind = canonicalKind(parts[0]) {
            let resolvedTopic = clipTopic(parts.dropFirst().joined(separator: " / "))
            return (mappedKind, resolvedTopic.isEmpty ? nil : resolvedTopic, remainder)
        }

        if parts.count == 1, let single = parts.first, let mappedKind = canonicalKind(single) {
            return (mappedKind, nil, remainder)
        }

        return (nil, clipTopic(tagContent), remainder)
    }

    private static func unwrapSimpleMarkdown(_ text: String) -> String {
        var result = text
        for marker in ["**", "__"] {
            while let open = result.range(of: marker),
                  let close = result.range(of: marker, range: open.upperBound..<result.endIndex) {
                let inner = String(result[open.upperBound..<close.lowerBound])
                result.replaceSubrange(open.lowerBound..<close.upperBound, with: inner)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipTopic(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = clean.last, last == ":" || last == "：" {
            clean.removeLast()
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > maxTopicLength {
            return String(clean.prefix(maxTopicLength))
        }
        return clean
    }

    // MARK: - Kind & Topic Inference

    private static func canonicalKind(_ token: String) -> String? {
        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = kindAliases[lower] {
            return mapped
        }
        if knownKinds.contains(lower) {
            return lower
        }
        return nil
    }

    private static func inferKind(fromHeading heading: String) -> String? {
        let lower = heading.lowercased()
        if containsAny(lower, ["偏好", "喜好", "习惯", "饮食", "口味", "忌口", "风格", "preference", "likes", "dislikes", "habits", "style", "taste"]) {
            return "preference"
        }
        if containsAny(lower, ["项目", "工程", "技术", "开发", "工作", "project", "work", "career", "tech", "stack"]) {
            return "project"
        }
        if containsAny(lower, ["规则", "原则", "约定", "指令", "要求", "禁忌", "rule", "guideline", "instruction", "constraint"]) {
            return "rule"
        }
        if containsAny(lower, ["目标", "计划", "打算", "goal", "plan", "roadmap"]) {
            return "goal"
        }
        if containsAny(lower, ["经历", "背景", "履历", "experience", "background", "education"]) {
            return "experience"
        }
        return nil
    }

    private static func inferKind(fromText text: String, topic: String) -> String {
        if let fromTopic = inferKind(fromHeading: topic) {
            return fromTopic
        }
        let lower = text.lowercased()
        if containsAny(lower, ["喜欢", "不喜欢", "不吃", "爱喝", "爱吃", "讨厌", "偏好", "习惯", "prefers", "prefer ", "likes ", "dislikes ", "favorite"]) {
            return "preference"
        }
        if containsAny(lower, ["正在做", "开发", "项目", "仓库", "building ", "working on ", "project "]) {
            return "project"
        }
        if containsAny(lower, ["不要", "必须", "一律", "始终", "请总是", "never ", "always ", "must "]) {
            return "rule"
        }
        if containsAny(lower, ["计划", "目标", "打算", "今年想", "准备去", "plan to", "goal is"]) {
            return "goal"
        }
        if containsAny(lower, ["曾经", "以前", "毕业于", "工作过", "去过", "used to ", "graduated"]) {
            return "experience"
        }
        return "fact"
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    // MARK: - Secret Detection & Redaction

    private static func containsSecret(_ text: String, orderedSecrets: [String]) -> Bool {
        if text.contains("〔隐去〕") {
            return true
        }
        if !orderedSecrets.isEmpty && MemorySafety.redactSecrets(text, secrets: orderedSecrets) != text {
            return true
        }
        for pattern in tokenSecretPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        if hasSecretAssignment(in: text) {
            return true
        }
        return false
    }

    private static func hasSecretAssignment(in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: assignmentSecretPattern, options: []) else {
            return false
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, options: [], range: nsRange) {
            guard match.numberOfRanges >= 2,
                  let rhsRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let rhs = String(text[rhsRange])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`,;。；{}[]")))
                .lowercased()
            if rhs.count >= 4 && !harmlessSecretPlaceholders.contains(rhs) {
                return true
            }
        }
        return false
    }
}
