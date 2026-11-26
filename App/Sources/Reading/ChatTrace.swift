import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

private final class TraceKeepsakeKey: NSObject {
    let line: ChatLine
    let desk: String
    private let cachedHash: Int

    init(line: ChatLine, desk: String) {
        self.line = line
        self.desk = desk
        var hasher = Hasher()
        hasher.combine(line.id)
        hasher.combine(line.tools.count)
        hasher.combine(line.details.count)
        hasher.combine(desk)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TraceKeepsakeKey else { return false }
        return cachedHash == other.cachedHash
            && desk == other.desk
            && line == other.line
    }
}

private final class TraceKeepsakeBox {
    let items: [Trace.Keepsake]
    let remembered: [Trace.Remembered]
    let pages: [URL]
    let mountRevision: UInt64

    init(
        items: [Trace.Keepsake],
        remembered: [Trace.Remembered],
        pages: [URL],
        mountRevision: UInt64
    ) {
        self.items = items
        self.remembered = remembered
        self.pages = pages
        self.mountRevision = mountRevision
    }
}

@MainActor
private enum TraceKeepsakeCache {
    struct Snapshot {
        let items: [Trace.Keepsake]
        let remembered: [Trace.Remembered]
        let pages: [URL]
    }

    private static let cache: NSCache<TraceKeepsakeKey, TraceKeepsakeBox> = {
        let cache = NSCache<TraceKeepsakeKey, TraceKeepsakeBox>()
        cache.countLimit = 200
        _ = NotificationCenter.default.addObserver(forName: MountedFolders.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TraceKeepsakeCache.clear() }
        }
        return cache
    }()

    static func clear() {
        cache.removeAllObjects()
    }

    static func get(line: ChatLine, desk: String) -> Snapshot? {
        let key = TraceKeepsakeKey(line: line, desk: desk)
        guard let box = cache.object(forKey: key) else { return nil }
        if box.mountRevision != MountedFolders.revision {
            cache.removeObject(forKey: key)
            return nil
        }
        return Snapshot(items: box.items, remembered: box.remembered, pages: box.pages)
    }

    static func set(
        _ items: [Trace.Keepsake],
        remembered: [Trace.Remembered],
        pages: [URL],
        line: ChatLine,
        desk: String,
        mountRevision: UInt64 = MountedFolders.revision
    ) {
        guard mountRevision == MountedFolders.revision else { return }
        let box = TraceKeepsakeBox(items: items, remembered: remembered, pages: pages, mountRevision: mountRevision)
        cache.setObject(box, forKey: TraceKeepsakeKey(line: line, desk: desk))
    }
}

enum TraceStepStatus: Equatable, Sendable {
    case ok, failed, cancelled, unknown

    nonisolated static func parse(_ label: String, output: String? = nil) -> (status: TraceStepStatus, clean: String) {
        if label.hasSuffix("（没成功）") {
            let clean = String(label.dropLast(5)).trimmingCharacters(in: .whitespaces)
            if let output,
               output.hasPrefix("用户没有同意这次操作")
                || output.hasPrefix("这一轮已经停下，这一步没有做") {
                return (.cancelled, clean)
            }
            return (.failed, clean)
        }
        if label.hasSuffix("（结果未知）") {
            return (.unknown, String(label.dropLast(6)).trimmingCharacters(in: .whitespaces))
        }
        return (.ok, label)
    }

    /// Only steps known to have succeeded produce outcome cards (calendar, reminder, file edits, etc.).
    nonisolated var allowsOutcomeCard: Bool { self == .ok }

    /// Commands keep executed failures and unknown outcomes (so users can inspect logs without losing status),
    /// while skipping commands that were rejected, cancelled, blocked, or empty before running.
    nonisolated static func shouldKeepCommand(status: TraceStepStatus, output: String) -> Bool {
        if status == .ok { return true }
        if status == .cancelled { return false }
        let skipped = output == "命令是空的。"
            || output.hasPrefix("用户没有同意这次操作")
            || output.hasPrefix("这一轮已经停下，这一步没有做")
            || output.hasPrefix("这一步刚才结果未知，同样的事没有再做一次")
        return !skipped
    }
}

enum TraceAggregateStatus: Equatable, Sendable {
    case succeeded
    case partial
    case failed
    case cancelled
    case running
    case pending
    case waitingApproval

    var symbolName: String {
        switch self {
        case .succeeded: "checkmark.circle"
        case .partial: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .running: "arrow.trianglehead.2.clockwise"
        case .pending: "circle.dotted"
        case .waitingApproval: "exclamationmark.shield"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .succeeded: Ink.ok
        case .partial, .waitingApproval: Ink.warn
        case .failed: Ink.stop
        case .cancelled: Ink.inkSoft
        case .running: Ink.accent
        case .pending: Ink.inkFaint
        }
    }

    @MainActor var label: String {
        switch self {
        case .succeeded: L.t("trace.statusSucceeded")
        case .partial: L.t("trace.statusPartial")
        case .failed: L.t("trace.statusFailed")
        case .cancelled: L.t("trace.statusCancelled")
        case .running: L.t("trace.statusRunning")
        case .pending: L.t("trace.statusPending")
        case .waitingApproval: L.t("trace.statusWaitingApproval")
        }
    }
}

/// 行迹: one line when closed, a timeline when open. A running trace shows its newest step.
struct Trace: View {
    let line: ChatLine
    var visit: (URL) -> Void = { _ in }
    var openFile: (URL, MountedFolder?) -> Void = { _, _ in }
    /// Takes back something the companion wrote into 拾遗 in these steps. False: it was not there any more.
    var unremember: ((String, String) -> Bool)?
    var initiallyOpen: Bool
    @State private var undone: Set<String> = []
    @State private var keepsakes: [Keepsake]
    @State private var rememberedItems: [Remembered]
    @State private var openedPages: [URL]
    @State private var hasCachedData: Bool
    @State private var mountRevision = MountedFolders.revision
    @State private var open: Bool

    @MainActor
    init(
        line: ChatLine,
        visit: @escaping (URL) -> Void = { _ in },
        openFile: @escaping (URL, MountedFolder?) -> Void = { _, _ in },
        unremember: ((String, String) -> Bool)? = nil,
        initiallyOpen: Bool = Pref.traceOpen
    ) {
        self.line = line
        self.visit = visit
        self.openFile = openFile
        self.unremember = unremember
        self.initiallyOpen = initiallyOpen
        self._open = State(initialValue: initiallyOpen)
        if !line.live, let cached = TraceKeepsakeCache.get(line: line, desk: Words.t("书案/")) {
            _keepsakes = State(initialValue: cached.items)
            _rememberedItems = State(initialValue: cached.remembered)
            _openedPages = State(initialValue: cached.pages)
            _hasCachedData = State(initialValue: true)
        } else {
            _keepsakes = State(initialValue: [])
            _rememberedItems = State(initialValue: [])
            _openedPages = State(initialValue: [])
            _hasCachedData = State(initialValue: false)
        }
    }

    private enum CanonicalPlace {
        case desk
        case shell
        case remote
        case browser
    }

    struct PrewarmedTraceSummary: Sendable {
        fileprivate let keepsakes: [Keepsake]
        fileprivate let remembered: [Remembered]
        fileprivate let pages: [URL]
        let mountRevision: UInt64
    }

    /// True when the steps row can render as a pure UIKit 1-line summary cell (no open drawer or inline outcome cards).
    /// Never performs synchronous disk/mount resolution (`WorkspaceFileRef.resolve`) on `@MainActor`.
    @MainActor
    static func shouldUseSummaryCell(for line: ChatLine) -> Bool {
        guard !Pref.traceOpen else { return false }
        if line.live {
            return buildPages(line).isEmpty
        }
        let desk = Words.t("书案/")
        if let cached = TraceKeepsakeCache.get(line: line, desk: desk) {
            return cached.items.isEmpty && cached.remembered.isEmpty && cached.pages.isEmpty
        }
        if !buildPages(line).isEmpty || !buildRemembered(line).isEmpty || hasSynchronousOutcomeKeepsake(line) {
            return false
        }
        if mayReferenceWorkspaceFiles(line) {
            return false
        }
        TraceKeepsakeCache.set([], remembered: [], pages: [], line: line, desk: desk)
        return true
    }

    @MainActor
    static func hasCachedSummaryEligibility(for line: ChatLine) -> Bool {
        TraceKeepsakeCache.get(line: line, desk: Words.t("书案/")) != nil
    }

    @MainActor
    static func clearSummaryCache() {
        TraceKeepsakeCache.clear()
    }

    nonisolated static func prewarmKeepsakePayload(
        for line: ChatLine,
        desk: String,
        mountRevision: UInt64
    ) -> PrewarmedTraceSummary {
        PrewarmedTraceSummary(
            keepsakes: buildKeepsakes(line, desk: desk),
            remembered: buildRemembered(line),
            pages: buildPages(line),
            mountRevision: mountRevision
        )
    }

    @MainActor
    static func commitPrewarmedSummary(_ payload: PrewarmedTraceSummary, for line: ChatLine, desk: String) -> Bool {
        guard payload.mountRevision == MountedFolders.revision else { return false }
        let currentOnly = payload.keepsakes.filter { item in
            item.mount.map(MountedFolders.isCurrent) ?? true
        }
        TraceKeepsakeCache.set(
            currentOnly,
            remembered: payload.remembered,
            pages: payload.pages,
            line: line,
            desk: desk,
            mountRevision: payload.mountRevision
        )
        return !Pref.traceOpen && currentOnly.isEmpty && payload.remembered.isEmpty && payload.pages.isEmpty
    }

    nonisolated private static func canonicalPlace(of label: String) -> CanonicalPlace? {
        guard let kind = canonicalKind(of: label) else { return nil }
        if kind == canonicalKind(of: "文件") { return .desk }
        if kind == canonicalKind(of: "终端") { return .shell }
        if kind == canonicalKind(of: "远程主机") { return .remote }
        if kind == canonicalKind(of: "浏览器") { return .browser }
        return nil
    }

    /// Pure in-memory check returning true when at least one step guarantees an outcome card
    /// without invoking `WorkspaceFileRef.resolve`.
    nonisolated static func hasSynchronousOutcomeKeepsake(_ line: ChatLine) -> Bool {
        for (index, tool) in line.tools.enumerated() {
            let parsed = TraceStepStatus.parse(tool)
            let status = parsed.status
            let cleanTool = parsed.clean
            let detail = index < line.details.count ? line.details[index] : nil
            let output = detail?.output ?? ""
            let parts = cleanTool.split(separator: "：", maxSplits: 1).map(String.init)
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : cleanTool
            let place = canonicalPlace(of: cleanTool)

            if status.allowsOutcomeCard {
                if cleanTool.hasPrefix("新建日程：")
                    || cleanTool.hasPrefix("加提醒：")
                    || (cleanTool.hasPrefix("查天气：") && !output.isEmpty && !output.hasPrefix("没找到"))
                    || (cleanTool.hasPrefix("健康：") && !output.isEmpty) {
                    return true
                }
            }

            if let toolName = detail?.tool, !toolName.isEmpty {
                let args = detail.flatMap { JSONValue.parse($0.input) }
                switch toolName {
                case "write_file", "edit_file":
                    guard status.allowsOutcomeCard else { continue }
                    let fallbackPath = (rest.hasPrefix("写 ") || rest.hasPrefix("改 "))
                        ? String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        : ""
                    let rawPath = (args?["path"]?.string ?? fallbackPath).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty && (place == .shell || place == .remote) {
                        return true
                    }
                case "shell":
                    if args?["background"]?.bool == true { continue }
                    if let job = args?["job"]?.string, !job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    if TraceStepStatus.shouldKeepCommand(status: status, output: output) {
                        return true
                    }
                case "ssh_run":
                    if TraceStepStatus.shouldKeepCommand(status: status, output: output) {
                        return true
                    }
                default:
                    break
                }
                continue
            }

            if place == .shell || place == .remote {
                if ["读 ", "找 ", "搜 ", "翻看 ", "看图 ", "看后台任务", "看看后台任务", "停掉后台任务", "后台跑"].contains(where: { rest.hasPrefix($0) }) {
                    continue
                }
                if rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                    if status.allowsOutcomeCard { return true }
                    continue
                }
                if TraceStepStatus.shouldKeepCommand(status: status, output: output) {
                    return true
                }
            }
        }
        return false
    }

    /// Pure string/tool-name check returning true when any step may resolve a workspace file
    /// (requiring off-main `WorkspaceFileRef.resolve`).
    nonisolated static func mayReferenceWorkspaceFiles(_ line: ChatLine) -> Bool {
        for (index, tool) in line.tools.enumerated() {
            let parsed = TraceStepStatus.parse(tool)
            let status = parsed.status
            let cleanTool = parsed.clean
            let detail = index < line.details.count ? line.details[index] : nil
            let output = detail?.output ?? ""
            let parts = cleanTool.split(separator: "：", maxSplits: 1).map(String.init)
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : cleanTool
            let place = canonicalPlace(of: cleanTool)

            if status.allowsOutcomeCard {
                if cleanTool.hasPrefix("新建日程：")
                    || cleanTool.hasPrefix("加提醒：")
                    || (cleanTool.hasPrefix("查天气：") && !output.isEmpty && !output.hasPrefix("没找到"))
                    || (cleanTool.hasPrefix("健康：") && !output.isEmpty) {
                    continue
                }
            }

            if let toolName = detail?.tool, !toolName.isEmpty {
                switch toolName {
                case "write_file", "edit_file":
                    guard status.allowsOutcomeCard, place != .shell, place != .remote else { continue }
                    let args = detail.flatMap { JSONValue.parse($0.input) }
                    let fallbackPath = (rest.hasPrefix("写 ") || rest.hasPrefix("改 "))
                        ? String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        : ""
                    let rawPath = (args?["path"]?.string ?? fallbackPath).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawPath.isEmpty { return true }
                case "make_document":
                    guard status.allowsOutcomeCard else { continue }
                    if rest.hasPrefix("写 ") {
                        let candidate = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        if !candidate.isEmpty { return true }
                    }
                    if output.hasPrefix("做好了：") {
                        let after = String(output.dropFirst(4))
                        let candidate = String(after.split(separator: "（", maxSplits: 1).first ?? Substring(after)).trimmingCharacters(in: .whitespaces)
                        if !candidate.isEmpty { return true }
                    }
                default:
                    break
                }
                continue
            }

            if status.allowsOutcomeCard, place == .desk, rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                return true
            }
        }
        return false
    }

    @MainActor
    static func needsOffMainKeepsakePrewarm(for line: ChatLine) -> Bool {
        guard !Pref.traceOpen, !line.live else { return false }
        guard !hasCachedSummaryEligibility(for: line) else { return false }
        guard buildPages(line).isEmpty, buildRemembered(line).isEmpty, !hasSynchronousOutcomeKeepsake(line) else {
            return false
        }
        return mayReferenceWorkspaceFiles(line)
    }

    nonisolated static func aggregateStatus(for line: ChatLine, waitingApproval: Bool = false) -> TraceAggregateStatus {
        if waitingApproval { return .waitingApproval }
        if line.live {
            return line.tools.isEmpty ? .pending : .running
        }
        if line.tools.isEmpty { return .succeeded }
        var okCount = 0
        var failedCount = 0
        var cancelledCount = 0
        var unknownCount = 0
        for (index, tool) in line.tools.enumerated() {
            let output = index < line.details.count ? line.details[index].output : nil
            switch TraceStepStatus.parse(tool, output: output).status {
            case .ok: okCount += 1
            case .failed: failedCount += 1
            case .cancelled: cancelledCount += 1
            case .unknown: unknownCount += 1
            }
        }
        if failedCount == 0 && cancelledCount == 0 && unknownCount == 0 {
            return .succeeded
        }
        if okCount == 0 && failedCount == 0 && unknownCount == 0 && cancelledCount > 0 {
            return .cancelled
        }
        if okCount == 0 && (failedCount > 0 || unknownCount > 0) {
            return .failed
        }
        return .partial
    }

    nonisolated static func summaryDisplayText(for line: ChatLine) -> String {
        if line.live {
            guard let current = line.tools.last else { return "沉吟" }
            return "第 \(line.tools.count) 步：" + current
        }
        var kinds: [String] = []
        for tool in line.tools {
            let kind = String(tool.split(whereSeparator: { $0 == "：" || $0 == "·" }).first ?? Substring(tool)).trimmingCharacters(in: .whitespaces)
            if !kind.isEmpty, !kinds.contains(kind) { kinds.append(kind) }
        }
        var out = "\(line.tools.count) 步"
        if !kinds.isEmpty { out += " · " + kinds.prefix(3).joined(separator: "、") + (kinds.count > 3 ? " 等" : "") }
        if let seconds = line.seconds { out += " · " + Clock.said(seconds) }
        return out
    }

    /// Normalizes a step label's leading place/tool prefix across daily and literary tones.
    nonisolated static func canonicalKind(of label: String) -> String? {
        let head = String(label.split(separator: "：", maxSplits: 1).first ?? Substring(label)).trimmingCharacters(in: .whitespaces)
        let prefix = String(head.split(separator: "·", maxSplits: 1).first ?? Substring(head)).trimmingCharacters(in: .whitespaces)
        switch prefix {
        case "书案", "文件": return "书案"
        case "斗室", "终端": return "斗室"
        case "远山", "远程主机", "别馆": return "远山"
        case "远游", "浏览器", "漫游": return "远游"
        default: return nil
        }
    }

    private func forget(_ memory: Remembered, with unremember: (String, String) -> Bool) {
        Haptics.light()
        // Shown as taken back only if it was: an entry you wrote or edited stays, and so does this line.
        guard let id = memory.memoryID else { return }
        if unremember(id, memory.fact) {
            withAnimation(Ink.Motion.settle) { _ = undone.insert(id) }
        } else {
            Haptics.lock()
        }
    }

    /// What these steps wrote into 拾遗, as the model wrote it.
    fileprivate struct Remembered: Identifiable, Equatable, Sendable {
        let id: Int
        let memoryID: String?
        let fact: String
    }

    private var remembered: [Remembered] {
        hasCachedData ? rememberedItems : Self.buildRemembered(line)
    }

    nonisolated private static func buildRemembered(_ line: ChatLine) -> [Remembered] {
        line.tools.enumerated().compactMap { index, tool in
            guard tool.hasPrefix("记住："), !tool.hasSuffix("（没成功）"), index < line.details.count,
                  line.details[index].output.hasPrefix("记下了"),
                  let fact = JSONValue.parse(line.details[index].input)?["fact"]?.string else { return nil }
            let id = line.details[index].full.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            return Remembered(id: index, memoryID: id, fact: fact.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the steps left behind worth a card: a date set, a reminder, a file written, a command run.
    fileprivate struct Keepsake: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case event, reminder, file, remoteFile, command, health, weather }
        let id: Int
        let kind: Kind
        let title: String
        let detail: String
        var url: URL?
        var mount: MountedFolder?
        /// A changed file's whole comparison.
        var diff: String?
        var place: String?
        /// Path without ` · −X +Y 行` so `changesCard` does not repeat or disagree with its right-side tally.
        var cleanDetail: String?
        /// For `.command`: true when `title` comes from the model's `step_title` rather than raw shell text.
        var humanTitle: Bool = false
        /// For `.command`: full untouched command and output opened when the card or row is tapped.
        var rawCommand: String?
        var fullOutput: String?
        var seconds: Int?
        var status: TraceStepStatus = .ok

        var displayDetail: String { place.map { Words.t($0) + " · " + detail } ?? detail }
        func changesDetail(hasTally: Bool) -> String {
            let base = hasTally ? (cleanDetail ?? detail) : detail
            return place.map { Words.t($0) + " · " + base } ?? base
        }
        var commandTitle: String { humanTitle ? title : "# " + title }
        var commandLinePreview: String {
            let last = detail.split(separator: "\n", omittingEmptySubsequences: true)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? detail
            return place.map { Words.t($0) + " · " + last } ?? last
        }
    }

    /// A file change opened to its whole comparison.
    private struct DiffShow: Identifiable {
        let id = UUID()
        let title: String
        let place: String
        let diff: String
        let url: URL?
        let mount: MountedFolder?
    }

    /// A terminal / SSH command opened to its full command text and full output.
    private struct CommandShow: Identifiable {
        let id = UUID()
        let title: String
        let place: String?
        let seconds: Int?
        let status: TraceStepStatus
        let command: String
        let output: String
    }

    @State private var diffing: DiffShow?
    @State private var inspectingCommand: CommandShow?
    @State private var commandsOpen = false

    /// A file to read rather than code to review — a report, a page, a picture: a tap opens it to read, as other
    /// agents do, instead of a comparison of lines.
    private static func isDocument(_ item: Keepsake) -> Bool {
        guard let url = item.url else { return false }
        let kinds: Set<String> = ["md", "markdown", "txt", "pdf", "doc", "docx", "rtf", "pages", "xls", "xlsx", "csv", "numbers",
                                  "ppt", "pptx", "key", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "html", "htm",
                                  "mp3", "m4a", "wav", "mp4", "mov"]
        return kinds.contains(url.pathExtension.lowercased())
    }

    private var activeKeepsakes: [Keepsake] {
        keepsakes.filter { item in
            item.mount.map(MountedFolders.isCurrent) ?? true
        }
    }

    /// The files these steps wrote or changed.
    private var changedFiles: [Keepsake] { activeKeepsakes.filter { $0.kind == .file || $0.kind == .remoteFile } }

    /// The shell / SSH commands these steps ran.
    private var ranCommands: [Keepsake] { activeKeepsakes.filter { $0.kind == .command } }

    /// Keepsakes rendered as standalone cards (excluding grouped multi-file and multi-command batches).
    private var standaloneKeepsakes: [Keepsake] {
        let groupFiles = changedFiles.count >= 2
        let groupCommands = ranCommands.count >= 2
        return activeKeepsakes.filter { item in
            if groupFiles, item.kind == .file || item.kind == .remoteFile { return false }
            if groupCommands, item.kind == .command { return false }
            return true
        }
    }

    private func openCommand(_ item: Keepsake) {
        DiagTrail.record("开命令详情")
        let command = (item.rawCommand ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = item.fullOutput ?? ""
        inspectingCommand = CommandShow(
            title: item.humanTitle ? item.title : L.t("trace.commandTitle"),
            place: item.place.map(Words.t),
            seconds: item.seconds,
            status: item.status,
            command: command,
            output: output
        )
    }

    private static func statusColor(_ status: TraceStepStatus, normal: Color) -> Color {
        switch status {
        case .ok: return normal
        case .failed: return Ink.stop
        case .cancelled: return Ink.inkSoft
        case .unknown: return Ink.warn
        }
    }

    /// Lines added and taken out, read off a comparison.
    private static func tally(_ diff: String?) -> (added: Int, removed: Int) {
        guard let diff else { return (0, 0) }
        var added = 0, removed = 0
        for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if row.hasPrefix("+"), !row.hasPrefix("+++") { added += 1 }
            if row.hasPrefix("-"), !row.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// Several files changed in one go: one card, 「改动了 3 个文件 +120 −40」, a row for each, opened to its comparison.
    private var changesCard: some View {
        let files = changedFiles
        let counts = files.map { Self.tally($0.diff) }
        let added = counts.reduce(0) { $0 + $1.added }
        let removed = counts.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft)
                Text("改动了 \(files.count) 个文件").font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                tallyText(added, removed)
            }
            .padding(Ink.Space.l)
            ForEach(Array(files.enumerated()), id: \.element.id) { index, item in
                let hasTally = counts[index].added > 0 || counts[index].removed > 0
                Kit.rule(inset: Ink.Space.l)
                Button {
                    guard item.mount.map(MountedFolders.isCurrent) ?? true else { return }
                    Haptics.light()
                    if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                        diffing = DiffShow(title: item.title, place: item.changesDetail(hasTally: hasTally), diff: diff, url: item.url, mount: item.mount)
                    } else if let url = item.url {
                        openFile(url, item.mount)
                    }
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        let fresh = counts[index].removed == 0 && counts[index].added > 0
                        Image(systemName: fresh ? "doc.badge.plus" : "doc.text")
                            .font(.system(size: Ink.Size.body)).foregroundStyle(fresh ? Ink.ok : Ink.inkSoft).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.title).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                if fresh { Text("新建").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.ok) }
                            }
                            Text(item.changesDetail(hasTally: hasTally)).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                        }
                        Spacer(minLength: Ink.Space.s)
                        tallyText(counts[index].added, counts[index].removed)
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .paperCard()
        .padding(.top, Ink.Space.s)
    }

    /// Several commands run in one go: one collapsible card so long debugging turns stay scannable,
    /// with each row tappable to inspect the full command and full output.
    private var commandsCard: some View {
        let commands = ranCommands
        let failedCount = commands.filter { $0.status == .failed }.count
        let unknownCount = commands.filter { $0.status == .unknown }.count
        let headerIconColor: Color
        if failedCount == commands.count {
            headerIconColor = Ink.stop
        } else if failedCount + unknownCount == commands.count && unknownCount > 0 {
            headerIconColor = Ink.warn
        } else {
            headerIconColor = Ink.inkSoft
        }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(Ink.Motion.unfold) { commandsOpen.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "terminal")
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(headerIconColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Ink.Space.s) {
                            Text(L.format("trace.commandsCount", commands.count))
                                .font(.system(size: Ink.Size.sub, weight: .semibold))
                                .foregroundStyle(Ink.ink)
                            if failedCount > 0 {
                                Text(L.format("trace.commandsFailedCount", failedCount))
                                    .font(.system(size: Ink.Size.micro, weight: .medium))
                                    .foregroundStyle(Ink.stop)
                            }
                            if unknownCount > 0 {
                                Text(L.format("trace.commandsUnknownCount", unknownCount))
                                    .font(.system(size: Ink.Size.micro, weight: .medium))
                                    .foregroundStyle(Ink.warn)
                            }
                        }
                        if !commandsOpen, let latest = commands.last {
                            Text(latest.commandTitle)
                                .font(latest.humanTitle ? Ink.footnote : Ink.mono(Ink.Size.micro))
                                .foregroundStyle(Self.statusColor(latest.status, normal: Ink.inkFaint).opacity(latest.status == .ok ? 1 : 0.85))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Ink.Space.s)
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(commandsOpen ? -180 : 0))
                }
                .padding(Ink.Space.l)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(haptic: false))
            if commandsOpen {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, item in
                    Kit.rule(inset: Ink.Space.l)
                    commandRow(item, index: index)
                }
            }
        }
        .paperCard()
        .padding(.top, Ink.Space.s)
    }

    private func commandRow(_ item: Keepsake, index: Int) -> some View {
        Button {
            Haptics.light()
            openCommand(item)
        } label: {
            HStack(alignment: .top, spacing: Ink.Space.m) {
                Text("\(index + 1)")
                    .font(Ink.mono(Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Self.statusColor(item.status, normal: Ink.inkFaint))
                    .frame(width: 20, alignment: .trailing)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.commandTitle)
                        .font(item.humanTitle ? .system(size: Ink.Size.sub, weight: .medium) : Ink.mono(Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.commandLinePreview)
                        .font(Ink.mono(Ink.Size.micro))
                        .foregroundStyle(Self.statusColor(item.status, normal: Ink.inkFaint).opacity(item.status == .ok ? 1 : 0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: Ink.Space.s)
                if item.status == .failed {
                    Text(L.t("trace.commandFailed"))
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.stop)
                        .padding(.top, 2)
                } else if item.status == .unknown {
                    Text(L.t("trace.commandUnknown"))
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.warn)
                        .padding(.top, 2)
                } else if let seconds = item.seconds, seconds >= 2 {
                    Text(Clock.said(seconds))
                        .font(.system(size: Ink.Size.micro).monospacedDigit())
                        .foregroundStyle(Ink.inkFaint)
                        .padding(.top, 2)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
                    .padding(.top, 3)
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func tallyText(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(Ink.ok) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Ink.stop) }
        }
        .font(Ink.mono(Ink.Size.small))
    }

    private struct KeepsakeInput: Equatable, Sendable {
        let line: ChatLine
        let desk: String
        let mountRevision: UInt64
    }

    nonisolated private static func upsertLocalFile(
        into out: inout [Keepsake],
        index: Int,
        ref: WorkspaceFileRef,
        desk: String,
        output: String,
        full: String?
    ) {
        let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
        let pathText = desk + ref.relativePath
        if let kept = out.firstIndex(where: { $0.url == ref.url && $0.mount?.id == ref.mount?.id }) {
            out[kept] = Keepsake(
                id: out[kept].id,
                kind: .file,
                title: ref.url.lastPathComponent,
                detail: pathText + " · 改了几次，这是最后一次",
                url: ref.url,
                mount: ref.mount,
                diff: full ?? out[kept].diff,
                cleanDetail: pathText + " · 改了几次，这是最后一次"
            )
        } else {
            out.append(Keepsake(
                id: index,
                kind: .file,
                title: ref.url.lastPathComponent,
                detail: pathText + change,
                url: ref.url,
                mount: ref.mount,
                diff: full,
                cleanDetail: pathText
            ))
        }
    }

    nonisolated private static func resolvedCommandOutput(full: String?, output: String) -> String {
        if let full, !full.isEmpty { return full }
        return output
    }

    nonisolated private static func buildKeepsakes(_ line: ChatLine, desk: String) -> [Keepsake] {
        var out: [Keepsake] = []
        for (index, tool) in line.tools.enumerated() {
            if Task.isCancelled { break }
            let parsed = TraceStepStatus.parse(tool)
            let status = parsed.status
            let cleanTool = parsed.clean
            let detail = index < line.details.count ? line.details[index] : nil
            let output = detail?.output ?? ""
            let full = detail?.full
            let parts = cleanTool.split(separator: "：", maxSplits: 1).map(String.init)
            let head = parts.first ?? cleanTool
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : cleanTool
            let kind = canonicalKind(of: cleanTool)

            if status.allowsOutcomeCard {
                if cleanTool.hasPrefix("新建日程：") {
                    out.append(Keepsake(id: index, kind: .event, title: String(cleanTool.dropFirst(5)), detail: "已加进日历", url: URL(string: "calshow://")))
                    continue
                } else if cleanTool.hasPrefix("加提醒：") {
                    out.append(Keepsake(id: index, kind: .reminder, title: String(cleanTool.dropFirst(4)), detail: "已加进提醒事项", url: URL(string: "x-apple-reminderkit://")))
                    continue
                } else if cleanTool.hasPrefix("查天气："), !output.isEmpty, !output.hasPrefix("没找到") {
                    out.append(Keepsake(id: index, kind: .weather, title: String(cleanTool.dropFirst(4)), detail: output))
                    continue
                } else if cleanTool.hasPrefix("健康："), !output.isEmpty {
                    out.append(Keepsake(id: index, kind: .health, title: String(cleanTool.dropFirst(3)), detail: output, url: URL(string: "x-apple-health://"), diff: full))
                    continue
                }
            }

            if let toolName = detail?.tool, !toolName.isEmpty {
                let args = detail.flatMap { JSONValue.parse($0.input) }
                switch toolName {
                case "write_file", "edit_file":
                    guard status.allowsOutcomeCard else { continue }
                    let fallbackPath = (rest.hasPrefix("写 ") || rest.hasPrefix("改 ")) ? String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) : ""
                    let rawPath = (args?["path"]?.string ?? fallbackPath).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawPath.isEmpty else { continue }
                    if kind == "斗室" || kind == "远山" {
                        let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                        let localRef = kind == "斗室" ? WorkspaceFileRef.resolve(rawPath) : nil
                        out.append(Keepsake(
                            id: index,
                            kind: .remoteFile,
                            title: (rawPath as NSString).lastPathComponent,
                            detail: rawPath + change,
                            url: localRef?.url,
                            mount: localRef?.mount,
                            diff: full,
                            place: head,
                            cleanDetail: rawPath
                        ))
                    } else if let ref = WorkspaceFileRef.resolve(rawPath) {
                        upsertLocalFile(into: &out, index: index, ref: ref, desk: desk, output: output, full: full)
                    }
                case "make_document":
                    guard status.allowsOutcomeCard else { continue }
                    var docPath = rest.hasPrefix("写 ") ? String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces) : ""
                    if docPath.isEmpty, output.hasPrefix("做好了：") {
                        let after = String(output.dropFirst(4))
                        docPath = String(after.split(separator: "（", maxSplits: 1).first ?? Substring(after)).trimmingCharacters(in: .whitespaces)
                    }
                    if !docPath.isEmpty, let ref = WorkspaceFileRef.resolve(docPath) {
                        upsertLocalFile(into: &out, index: index, ref: ref, desk: desk, output: output, full: full)
                    }
                case "shell":
                    if args?["background"]?.bool == true { continue }
                    if let job = args?["job"]?.string, !job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    guard TraceStepStatus.shouldKeepCommand(status: status, output: output) else { continue }
                    let cmd = (args?["command"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let stepTitle = (args?["step_title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let preview = commandPreview(cmd)
                    let isHuman = !stepTitle.isEmpty
                    let titleText = isHuman ? stepTitle : (!preview.isEmpty ? preview : rest)
                    let commandOutput = resolvedCommandOutput(full: full, output: output)
                    out.append(Keepsake(
                        id: index,
                        kind: .command,
                        title: titleText,
                        detail: outputTail(commandOutput),
                        place: kind == "远山" ? head : nil,
                        humanTitle: isHuman,
                        rawCommand: cmd.isEmpty ? rest : cmd,
                        fullOutput: commandOutput,
                        seconds: detail?.seconds,
                        status: status
                    ))
                case "ssh_run":
                    guard TraceStepStatus.shouldKeepCommand(status: status, output: output) else { continue }
                    let hostName = (args?["host"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let cmd = (args?["command"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let stepTitle = (args?["step_title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let preview = commandPreview(cmd)
                    let isHuman = !stepTitle.isEmpty
                    let titleText = isHuman ? stepTitle : (!preview.isEmpty ? preview : rest)
                    let placeText = hostName.isEmpty ? head : "\(head) · \(hostName)"
                    let commandOutput = resolvedCommandOutput(full: full, output: output)
                    out.append(Keepsake(
                        id: index,
                        kind: .command,
                        title: titleText,
                        detail: outputTail(commandOutput),
                        place: placeText,
                        humanTitle: isHuman,
                        rawCommand: cmd.isEmpty ? rest : cmd,
                        fullOutput: commandOutput,
                        seconds: detail?.seconds,
                        status: status
                    ))
                default:
                    break
                }
                continue
            }

            if status.allowsOutcomeCard, kind == "书案", rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                let rawPath = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let ref = WorkspaceFileRef.resolve(rawPath) {
                    upsertLocalFile(into: &out, index: index, ref: ref, desk: desk, output: output, full: full)
                }
            } else if kind == "斗室" || kind == "远山" {
                if ["读 ", "找 ", "搜 ", "翻看 ", "看图 ", "看后台任务", "看看后台任务", "停掉后台任务", "后台跑"].contains(where: { rest.hasPrefix($0) }) { continue }
                if rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                    guard status.allowsOutcomeCard else { continue }
                    let rawPath = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    let localRef = kind == "斗室" ? WorkspaceFileRef.resolve(rawPath) : nil
                    out.append(Keepsake(
                        id: index,
                        kind: .remoteFile,
                        title: (rawPath as NSString).lastPathComponent,
                        detail: rawPath + change,
                        url: localRef?.url,
                        mount: localRef?.mount,
                        diff: full,
                        place: head,
                        cleanDetail: rawPath
                    ))
                    continue
                }
                guard TraceStepStatus.shouldKeepCommand(status: status, output: output) else { continue }
                let preview = commandPreview(rest)
                let commandOutput = resolvedCommandOutput(full: full, output: output)
                out.append(Keepsake(
                    id: index,
                    kind: .command,
                    title: preview.isEmpty ? rest : preview,
                    detail: outputTail(commandOutput),
                    place: kind == "远山" ? head : nil,
                    rawCommand: rest,
                    fullOutput: commandOutput,
                    seconds: detail?.seconds,
                    status: status
                ))
            }
        }
        return out
    }

    @State private var peeking: Set<Int> = []

    /// Pages a companion opened in 远游 during these steps, newest last, each once.
    private var pages: [URL] {
        hasCachedData ? openedPages : Self.buildPages(line)
    }

    nonisolated private static func buildPages(_ line: ChatLine) -> [URL] {
        var seen: [URL] = []
        for (index, tool) in line.tools.enumerated() where !tool.hasSuffix("（没成功）") {
            let detail = index < line.details.count ? line.details[index] : nil
            if detail?.tool == "browser_open",
               let rawURL = JSONValue.parse(detail?.input ?? "")?["url"]?.string,
               let url = URL(string: rawURL), !seen.contains(url) {
                seen.append(url)
                continue
            }
            guard Self.canonicalKind(of: tool) == "远游" else { continue }
            let parts = tool.split(separator: "：", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("http"), let url = URL(string: target), !seen.contains(url) {
                seen.append(url)
            }
        }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let willOpen = !open
                DiagTrail.record(willOpen ? "展开步骤(\(line.tools.count)步)" : "收起步骤")
                withAnimation(Ink.Motion.unfold) { open.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    let agg = Self.aggregateStatus(for: line)
                    if agg == .running {
                        ProgressView().controlSize(.mini).tint(Ink.accent)
                    } else {
                        Image(systemName: agg.symbolName)
                            .font(.system(size: Ink.Size.sub, weight: .medium))
                            .foregroundStyle(agg.color)
                    }
                    Text(Words.t(Self.summaryDisplayText(for: line)))
                        .font(Ink.secondary)
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? -180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            // One line whether it works or is done (「第 3 步：搜索 重庆天气」); every step when you open it.
            if open {
                let hidden = 0
                VStack(alignment: .leading, spacing: 0) {
                    if hidden > 0 {
                        Button {
                            withAnimation(Ink.Motion.unfold) { open = true }
                        } label: {
                            Text("前面还有 \(hidden) 步")
                                .font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                .padding(.leading, 30).padding(.bottom, Ink.Space.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(line.tools.enumerated()).filter { $0.offset >= hidden }, id: \.offset) { index, tool in
                        step(tool, index: index, last: index == line.tools.count - 1)
                    }
                }
                .padding(.top, Ink.Space.m)
                .transition(.asymmetric(
                    insertion: .opacity.animation(Ink.Motion.settle.delay(0.08)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
            }
        }
        .clipped()
        .task(id: line.live ? nil : KeepsakeInput(line: line, desk: Words.t("书案/"), mountRevision: mountRevision)) {
            guard !line.live else {
                if !keepsakes.isEmpty { keepsakes = [] }
                if hasCachedData {
                    rememberedItems = []
                    openedPages = []
                    hasCachedData = false
                }
                return
            }
            let input = KeepsakeInput(line: line, desk: Words.t("书案/"), mountRevision: mountRevision)
            if let cached = TraceKeepsakeCache.get(line: input.line, desk: input.desk) {
                if keepsakes != cached.items { keepsakes = cached.items }
                if rememberedItems != cached.remembered { rememberedItems = cached.remembered }
                if openedPages != cached.pages { openedPages = cached.pages }
                hasCachedData = true
                return
            }
            let startMountRevision = MountedFolders.revision
            let job = Task.detached(priority: .utility) {
                (
                    keepsakes: Self.buildKeepsakes(input.line, desk: input.desk),
                    remembered: Self.buildRemembered(input.line),
                    pages: Self.buildPages(input.line)
                )
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            if !Task.isCancelled {
                let currentOnly = result.keepsakes.filter { item in
                    item.mount.map(MountedFolders.isCurrent) ?? true
                }
                if startMountRevision == MountedFolders.revision {
                    TraceKeepsakeCache.set(
                        currentOnly,
                        remembered: result.remembered,
                        pages: result.pages,
                        line: input.line,
                        desk: input.desk,
                        mountRevision: startMountRevision
                    )
                }
                if keepsakes != currentOnly { keepsakes = currentOnly }
                if rememberedItems != result.remembered { rememberedItems = result.remembered }
                if openedPages != result.pages { openedPages = result.pages }
                hasCachedData = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MountedFolders.changed)) { _ in
            if let show = diffing, let mount = show.mount, !MountedFolders.isCurrent(mount) {
                diffing = nil
            }
            let filtered = keepsakes.filter { item in
                item.mount.map(MountedFolders.isCurrent) ?? true
            }
            if filtered != keepsakes { keepsakes = filtered }
            mountRevision = MountedFolders.revision
        }
        .animation(Ink.Motion.settle, value: line.tools.count)
        // Done: everything folds into the initial state again.
        .onChange(of: line.live) { _, live in
            if !live { withAnimation(Ink.Motion.unfold) { open = initiallyOpen } }
        }
        if !line.live, changedFiles.count >= 2 {
            changesCard
        }
        if !line.live, ranCommands.count >= 2 {
            commandsCard
        }
        if !line.live {
            ForEach(standaloneKeepsakes) { item in
                Button {
                    Haptics.light()
                    switch item.kind {
                    case .file, .remoteFile:
                        guard item.mount.map(MountedFolders.isCurrent) ?? true else { return }
                        if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                            diffing = DiffShow(title: item.title, place: item.displayDetail, diff: diff, url: item.url, mount: item.mount)
                        } else if let url = item.url {
                            openFile(url, item.mount)
                        }
                    case .event, .reminder, .health: if let url = item.url { UIApplication.shared.open(url) }
                    case .weather: break
                    case .command: openCommand(item)
                    }
                } label: {
                    if item.kind == .health {
                        HealthCard(text: item.detail, format: item.diff)
                    } else if item.kind == .weather {
                        WeatherCard(text: item.detail)
                    } else {
                        standaloneKeepsakeBody(item)
                    }
                }
                .buttonStyle(PressStyle(haptic: false))
                .padding(.top, Ink.Space.s)
            }
        }
        if !line.live, let unremember {
            // 「记下了」: one quiet line per thing remembered, as Cindy's learning footer; 撤回 right there, or long-press.
            ForEach(remembered) { memory in
                let fact = memory.fact
                let gone = memory.memoryID.map(undone.contains) ?? false
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.xs) {
                    Image(systemName: gone ? "bookmark.slash" : "bookmark")
                        .font(.system(size: Ink.Size.micro))
                    Text(gone ? "撤回了：\(fact)" : "记下了：\(fact)")
                        .font(Ink.footnote)
                        .strikethrough(gone)
                        .lineLimit(2)
                    Spacer(minLength: Ink.Space.s)
                    if !gone, memory.memoryID != nil {
                        Button("撤回") { forget(memory, with: unremember) }
                            .font(.system(size: Ink.Size.small, weight: .medium))
                            .foregroundStyle(Ink.accent)
                            .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Ink.inkFaint)
                .padding(.top, Ink.Space.xs)
                .contentShape(Rectangle())
                .contextMenu {
                    if !gone, memory.memoryID != nil {
                        Button("撤回这条", systemImage: "bookmark.slash") { forget(memory, with: unremember) }
                    }
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = fact }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(gone ? "撤回了：\(fact)" : "记下了：\(fact)")
            }
        }
        Color.clear.frame(height: 0)
            .sheet(item: $diffing) { show in
                let mountValid = show.mount.map(MountedFolders.isCurrent) ?? true
                let openableURL = mountValid ? show.url : nil
                DiffSheet(title: show.title, place: show.place, diff: show.diff, url: openableURL) { url in
                    guard show.mount.map(MountedFolders.isCurrent) ?? true else {
                        diffing = nil
                        return
                    }
                    diffing = nil
                    openFile(url, show.mount)
                }
            }
        Color.clear.frame(height: 0)
            .sheet(item: $inspectingCommand) { show in
                CommandSheet(
                    title: show.title,
                    place: show.place,
                    seconds: show.seconds,
                    status: show.status,
                    command: show.command,
                    output: show.output
                )
            }
        if !pages.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.s) {
                    ForEach(pages, id: \.self) { url in
                        Button {
                            Haptics.light()
                            visit(url)
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Image(systemName: "safari").font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.host() ?? url.absoluteString).font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                                    Text(url.path().isEmpty || url.path() == "/" ? "首页" : url.path()).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, Ink.Space.m)
                            .padding(.vertical, Ink.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .paperCard()
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .padding(.top, Ink.Space.s)
        }
    }

    private func step(_ tool: String, index: Int, last: Bool) -> some View {
        let more = index < line.details.count ? line.details[index] : nil
        let parsed = TraceStepStatus.parse(tool, output: more?.output)
        let parts = parsed.clean.split(separator: "：", maxSplits: 1).map(String.init)
        let name = parts.first ?? parsed.clean
        let detail = parts.count > 1 ? parts[1] : nil
        let shown = peeking.contains(index)
        let stepSymbol: String
        let stepColor: Color
        switch parsed.status {
        case .ok:
            stepSymbol = Self.icon(for: name)
            stepColor = Ink.inkSoft
        case .failed:
            stepSymbol = "xmark.circle"
            stepColor = Ink.stop
        case .cancelled:
            stepSymbol = "stop.circle"
            stepColor = Ink.inkSoft
        case .unknown:
            stepSymbol = "questionmark.circle"
            stepColor = Ink.warn
        }
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(spacing: 0) {
                Image(systemName: stepSymbol)
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(stepColor)
                    .frame(width: 22, height: 22)
                if !last { Rectangle().fill(Ink.rule).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 2) }
            }
            VStack(alignment: .leading, spacing: 2) {
                // One line per step: what kind of thing, then what exactly. Time only when it was worth waiting for.
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    (Text(Words.t(Self.word(for: name))).foregroundStyle(Ink.ink).fontWeight(.medium)
                        + Text(detail.map { "  " + Words.t($0) } ?? "").foregroundStyle(Ink.inkSoft))
                        .font(.system(size: Ink.Size.sub))
                        .lineLimit(shown ? nil : 1)
                    Spacer(minLength: 0)
                    if let seconds = more?.seconds, seconds >= 2 {
                        Text(Clock.said(seconds)).font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkFaint)
                    }
                    if shown {
                        Image(systemName: "chevron.up").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                    }
                }
                .frame(minHeight: 22)
                if shown, let more {
                    TraceStepEvidence(detail: more)
                    .textSelection(.enabled)
                    .padding(Ink.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.mine.opacity(0.6), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .padding(.top, Ink.Space.xs)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : Ink.Space.s + 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard more != nil else { return }
                withAnimation(Ink.Motion.settle) {
                    if shown { peeking.remove(index) } else { peeking.insert(index) }
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func keepsakeIcon(_ kind: Keepsake.Kind) -> String {
        switch kind {
        case .event: "calendar.badge.checkmark"
        case .reminder: "checklist"
        case .file: "doc.text"
        case .remoteFile: "doc.badge.gearshape"
        case .command: "terminal"
        case .health: "heart.text.square"
        case .weather: "cloud.sun"
        }
    }

    /// Tool arguments as short lines: `key: value`.
    nonisolated static func tidy(_ json: String) -> String {
        guard let value = JSONValue.parse(json), case .object(let map) = value else { return json }
        return map.keys.sorted().map { key in
            let item = map[key]!
            return "\(key): \(item.string ?? item.compact)"
        }.joined(separator: "\n")
    }

    /// The glossary's names for what a tool does.
    static func word(for label: String) -> String {
        switch label {
        case "搜索": "寻访"
        case "读网页": Words.t("远游")
        case "记住": Words.t("拾遗")
        case "忘掉": Words.t("删去拾遗")
        case "看日历", "看提醒事项": "翻看"
        case "新建日程", "加提醒": Words.t("落印 · \(label)")
        default: label.hasPrefix("约好") ? "来信" : label
        }
    }

    static func icon(for label: String) -> String {
        switch label {
        case "搜索": return "magnifyingglass"
        case "读网页": return "globe"
        case "清单", "计划": return "list.bullet"
        case "写文件", "改文件": return "doc.text"
        case "读文件": return "doc"
        case "命令", "终端": return "terminal"
        default: break
        }
        return poeticIcon(label)
    }

    private static func poeticIcon(_ label: String) -> String {
        if let kind = canonicalKind(of: label) {
            switch kind {
            case "远游": return "safari"
            case "书案": return "books.vertical"
            case "斗室": return "terminal"
            case "远山": return "mountain.2"
            default: break
            }
        }
        switch Words.poetic(label) {
        case "搜索", "寻访": return "magnifyingglass"
        case "读网页": return "globe"
        case "远游", "漫游": return "safari"
        case "书案": return "books.vertical"
        case "斗室": return "terminal"
        case "所在", "位置": return "location"
        case "远山", "别馆": return "mountain.2"
        case "递笺", "便笺", "回笺": return "square.and.pencil"
        case "信匣", "密匣", "密码箱": return "lock.rectangle.stack"
        case "通讯录": return "person.crop.circle"
        case "相册": return "photo.on.rectangle"
        case "步数": return "figure.walk"
        case "剪贴板": return "doc.on.clipboard"
        case "打开": return "arrow.up.forward.app"
        case "手机": return "iphone"
        case "记住", "忘掉", "拾遗": return "bookmark"
        case "看日历", "新建日程": return "calendar"
        case "看提醒事项", "加提醒": return "checklist"
        default: return label.hasPrefix("约好") ? "envelope" : "wrench.and.screwdriver"
        }
    }

    private func standaloneKeepsakeBody(_ item: Keepsake) -> some View {
        let commandStatus: TraceStepStatus = item.kind == .command ? item.status : .ok
        let titleText = item.kind == .command ? item.commandTitle : item.title
        let titleFont: Font
        if item.kind == .command && !item.humanTitle {
            titleFont = Ink.mono(Ink.Size.small, weight: .medium)
        } else {
            titleFont = .system(size: Ink.Size.sub, weight: .medium)
        }
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            Image(systemName: Self.keepsakeIcon(item.kind))
                .font(.system(size: Ink.Size.body))
                .foregroundStyle(Self.statusColor(commandStatus, normal: Ink.accent))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(titleFont)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.displayDetail)
                    .font(item.kind == .command ? Ink.mono(Ink.Size.micro) : Ink.footnote)
                    .foregroundStyle(Self.statusColor(commandStatus, normal: Ink.inkSoft).opacity(commandStatus == .ok ? 1 : 0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                    // The first few changed lines, so the card shows what changed at a glance.
                    DiffText(hunk: DiffText.glance(diff), limit: 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            Spacer(minLength: 0)
            if commandStatus == .failed {
                Text(L.t("trace.commandFailed"))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.stop)
            } else if commandStatus == .unknown {
                Text(L.t("trace.commandUnknown"))
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.warn)
            }
            if item.kind != .remoteFile || item.diff != nil || item.url != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
            }
        }
        .padding(Ink.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    nonisolated private static func outputTail(_ output: String) -> String {
        let nonEmpty = output.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tail = nonEmpty.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "（没有输出）" : tail
    }

    /// Trims leading and trailing blank lines while keeping inner indentation intact.
    nonisolated static func trimmedEdgeBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Strips routine shell wrappers (`cd /root/desk &&`, `timeout N`, verbose `ssh -i/-o` flags) for one-line scanability.
    /// The untouched full command is always shown when tapped.
    nonisolated static func commandPreview(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        let startIndex = lines.firstIndex { isMeaningfulCommandLine($0) } ?? 0
        var current = lines[startIndex]
        var changed = true
        while changed {
            changed = false
            if let stripped = stripLeadingCD(current) {
                current = stripped
                changed = true
            }
            if let stripped = stripLeadingTimeout(current) {
                current = stripped
                changed = true
            }
        }
        if let sshSummary = compactSSHCommand(current, followingLines: Array(lines.dropFirst(startIndex + 1))) {
            current = sshSummary
        }
        if current.count > 100 {
            return String(current.prefix(100)) + "…"
        }
        return current
    }

    nonisolated private static func isMeaningfulCommandLine(_ line: String) -> Bool {
        if line.hasPrefix("#") { return false }
        if line == "set -e" || line == "set -eu" || line == "set -euo pipefail" || line == "set -o pipefail" { return false }
        return true
    }

    nonisolated private static func stripLeadingCD(_ text: String) -> String? {
        let prefixes = [
            "cd /root/desk && ", "cd /root/desk; ", "cd /root/desk &&", "cd /root/desk;",
            "cd /root && ", "cd /root; ", "cd /root &&", "cd /root;",
            "cd ~ && ", "cd ~; ", "cd ~ &&", "cd ~;"
        ]
        for prefix in prefixes where text.hasPrefix(prefix) {
            let tail = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { return tail }
        }
        return nil
    }

    nonisolated private static func stripLeadingTimeout(_ text: String) -> String? {
        guard text.hasPrefix("timeout ") else { return nil }
        var rest = text.dropFirst("timeout ".count).drop(while: { $0 == " " || $0 == "\t" })
        while rest.hasPrefix("-") {
            let flag = rest.prefix(while: { $0 != " " && $0 != "\t" })
            rest = rest.dropFirst(flag.count).drop(while: { $0 == " " || $0 == "\t" })
            if flag == "-k" || flag == "-s" {
                let arg = rest.prefix(while: { $0 != " " && $0 != "\t" })
                rest = rest.dropFirst(arg.count).drop(while: { $0 == " " || $0 == "\t" })
            }
        }
        let duration = rest.prefix(while: { $0 != " " && $0 != "\t" })
        guard !duration.isEmpty, duration.first?.isNumber == true else { return nil }
        let after = rest.dropFirst(duration.count).drop(while: { $0 == " " || $0 == "\t" })
        guard !after.isEmpty else { return nil }
        return String(after)
    }

    nonisolated private static func compactSSHCommand(_ text: String, followingLines: [String]) -> String? {
        guard text.hasPrefix("ssh ") else { return nil }
        let tokens = tokenizeShell(text)
        guard tokens.count >= 2, tokens[0] == "ssh" else { return nil }
        let valueFlags: Set<String> = [
            "-i", "-o", "-p", "-l", "-F", "-J", "-b", "-c", "-D", "-E",
            "-I", "-L", "-m", "-O", "-Q", "-R", "-S", "-W", "-w"
        ]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if token.hasPrefix("-") {
                index += valueFlags.contains(token) ? 2 : 1
            } else {
                break
            }
        }
        guard index < tokens.count else { return nil }
        let host = tokens[index]
        let restTokens = Array(tokens.dropFirst(index + 1))
        let joined = restTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let usesHeredoc = restTokens.first?.hasPrefix("<<") == true || restTokens.last?.hasPrefix("<<") == true
        let remote: String
        if joined.isEmpty || joined == "'" || joined == "\"" || usesHeredoc {
            remote = followingLines.first(where: { line in
                isMeaningfulCommandLine(line) && line != "EOF" && line != "EOS" && line != "END"
            }) ?? ""
        } else {
            remote = joined
        }
        return remote.isEmpty ? "ssh \(host)" : "ssh \(host): \(remote)"
    }

    nonisolated private static func tokenizeShell(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for ch in text {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if let active = quote {
                if active == "\"" && ch == "\\" {
                    escaping = true
                } else if ch == active {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\\" {
                escaping = true
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}


/// Tool arguments and any image are prepared only for an expanded step, without blocking scrolling.
private struct TraceStepEvidence: View {
    let detail: StepDetail
    @State private var prepared: Evidence?

    private struct Evidence {
        var input: String?
        var image: UIImage?
        var output: String
        var diff: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            if let prepared {
                if let input = prepared.input {
                    Text("交给它的").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                    Text(input).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(12)
                }
                if let image = prepared.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                }
                Text("它回来的").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                Text(prepared.output).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(24)
                if let diff = prepared.diff { DiffText(hunk: diff) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: detail) {
            prepared = nil
            let snapshot = detail
            let job = Task.detached(priority: .utility) {
                let input = snapshot.input.isEmpty || snapshot.input == "{}" ? nil : Trace.tidy(snapshot.input)
                let image = snapshot.photo.flatMap { name in
                    Disk.photo(name).flatMap { UIImage(data: $0) }
                }
                let diff = Diff.hunk(in: snapshot.output)
                let output = diff == nil
                    ? (snapshot.output.isEmpty ? "（空）" : String(snapshot.output.prefix(1500)))
                    : String(snapshot.output.prefix(while: { $0 != "\n" }))
                return Evidence(input: input, image: image, output: output, diff: diff)
            }
            let ready = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            if !Task.isCancelled { prepared = ready }
        }
    }
}


/// Full command and saved output for a shell / ssh step, opened when tapping a command card or row.
private struct CommandSheet: View {
    let title: String
    let place: String?
    let seconds: Int?
    let status: TraceStepStatus
    let command: String
    let output: String

    @Environment(\.dismiss) private var dismiss
    @State private var copiedField: String?

    private static let displayLimit = 40_000

    private var metadata: String? {
        var parts: [String] = []
        if let place, !place.isEmpty { parts.append(place) }
        if let seconds, seconds > 0 { parts.append(Clock.said(seconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var trimmedOutput: String {
        Trace.trimmedEdgeBlankLines(output)
    }

    private var shownOutput: String {
        let trimmed = trimmedOutput
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count > Self.displayLimit {
            return String(trimmed.prefix(Self.displayLimit))
                + "\n\n" + L.format("trace.outputTruncated", Self.displayLimit)
        }
        return trimmed
    }

    private var outputClippedUpstream: Bool {
        let trimmed = trimmedOutput
        return trimmed.hasSuffix("\n……")
            || trimmed.contains("\n……（中间省略 ")
            || trimmed.contains("……（输出太长")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    if status != .ok || metadata != nil {
                        VStack(alignment: .leading, spacing: Ink.Space.xs) {
                            if status == .failed {
                                Label(L.t("trace.commandFailedDetail"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: Ink.Size.small, weight: .medium))
                                    .foregroundStyle(Ink.stop)
                            } else if status == .cancelled {
                                Label(L.t("trace.statusCancelled"), systemImage: "stop.circle.fill")
                                    .font(.system(size: Ink.Size.small, weight: .medium))
                                    .foregroundStyle(Ink.inkSoft)
                            } else if status == .unknown {
                                Label(L.t("trace.commandUnknownDetail"), systemImage: "questionmark.circle.fill")
                                    .font(.system(size: Ink.Size.small, weight: .medium))
                                    .foregroundStyle(Ink.warn)
                            }
                            if let metadata {
                                Text(metadata)
                                    .font(Ink.footnote)
                                    .foregroundStyle(Ink.inkSoft)
                            }
                        }
                    }
                    codeSection(
                        label: L.t("trace.commandLabel"),
                        key: "cmd",
                        shown: Trace.trimmedEdgeBlankLines(command),
                        copyText: command
                    )
                    codeSection(
                        label: L.t("trace.outputLabel"),
                        key: "out",
                        shown: shownOutput.isEmpty ? L.t("trace.noOutput") : shownOutput,
                        copyText: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : output,
                        muted: shownOutput.isEmpty,
                        note: outputClippedUpstream ? L.t("trace.outputTrimmedNote") : nil
                    )
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { dismiss() }
                }
            }
        }
    }

    private func codeSection(
        label: String,
        key: String,
        shown: String,
        copyText: String?,
        muted: Bool = false,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack {
                Text(label)
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.inkSoft)
                Spacer()
                if let copyText, !copyText.isEmpty {
                    Button {
                        UIPasteboard.general.string = copyText
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { copiedField = key }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedField == key {
                                withAnimation(Ink.Motion.settle) { copiedField = nil }
                            }
                        }
                    } label: {
                        HStack(spacing: Ink.Space.xs) {
                            Image(systemName: copiedField == key ? "checkmark" : "doc.on.doc")
                            Text(copiedField == key ? L.t("trace.copied") : L.t("trace.copy"))
                        }
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(copiedField == key ? Ink.ok : Ink.inkSoft)
                        .padding(.horizontal, Ink.Space.s)
                        .frame(height: 26)
                        .background(Ink.paperRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(Ink.rule.opacity(0.7), lineWidth: 0.5))
                    }
                    .buttonStyle(PressStyle(haptic: false))
                }
            }
            Text(shown)
                .font(Ink.mono(Ink.Size.small))
                .foregroundStyle(muted ? Ink.inkFaint : Ink.ink)
                .lineSpacing(Ink.Size.small * 0.12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Ink.Space.m)
                .inkBlock()
            if let note {
                Text(note)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
            }
        }
    }
}
