import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// 行迹: one line when closed, a timeline when open. A running trace shows its newest step.
struct Trace: View {
    let line: ChatLine
    var visit: (URL) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    /// Takes back something the companion wrote into 拾遗 in these steps. False: it was not there any more.
    var unremember: ((String, String) -> Bool)?
    @State private var undone: Set<String> = []

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
    private struct Remembered: Identifiable {
        let id: Int
        let memoryID: String?
        let fact: String
    }

    private var remembered: [Remembered] {
        line.tools.enumerated().compactMap { index, tool in
            guard tool.hasPrefix("记住："), !tool.hasSuffix("（没成功）"), index < line.details.count,
                  line.details[index].output.hasPrefix("记下了"),
                  let fact = JSONValue.parse(line.details[index].input)?["fact"]?.string else { return nil }
            let id = line.details[index].full.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            return Remembered(id: index, memoryID: id, fact: fact.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the steps left behind worth a card: a date set, a reminder, a file written, a command run.
    private struct Keepsake: Identifiable, Sendable {
        enum Kind: Sendable { case event, reminder, file, remoteFile, command, health, weather }
        let id: Int
        let kind: Kind
        let title: String
        let detail: String
        var url: URL?
        /// A changed file's whole comparison.
        var diff: String?
        var place: String?

        var displayDetail: String { place.map { Words.t($0) + " · " + detail } ?? detail }
    }

    /// A file change opened to its whole comparison.
    private struct DiffShow: Identifiable {
        let id = UUID()
        let title: String
        let place: String
        let diff: String
        let url: URL?
    }
    @State private var diffing: DiffShow?

    /// A file to read rather than code to review — a report, a page, a picture: a tap opens it to read, as other
    /// agents do, instead of a comparison of lines.
    private static func isDocument(_ item: Keepsake) -> Bool {
        guard let url = item.url else { return false }
        let kinds: Set<String> = ["md", "markdown", "txt", "pdf", "doc", "docx", "rtf", "pages", "xls", "xlsx", "csv", "numbers",
                                  "ppt", "pptx", "key", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "html", "htm",
                                  "mp3", "m4a", "wav", "mp4", "mov"]
        return kinds.contains(url.pathExtension.lowercased())
    }

    /// The files these steps wrote or changed.
    private var changedFiles: [Keepsake] { keepsakes.filter { $0.kind == .file || $0.kind == .remoteFile } }

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
                Kit.rule(inset: Ink.Space.l)
                Button {
                    Haptics.light()
                    if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                        diffing = DiffShow(title: item.title, place: item.displayDetail, diff: diff, url: item.url)
                    } else if let url = item.url {
                        openFile(url)
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
                            Text(item.displayDetail).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
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
    }

    @State private var keepsakes: [Keepsake] = []

    nonisolated private static func buildKeepsakes(_ line: ChatLine, desk: String) -> [Keepsake] {
        var out: [Keepsake] = []
        for (index, tool) in line.tools.enumerated() where !tool.hasSuffix("（没成功）") {
            if Task.isCancelled { break }
            let output = index < line.details.count ? line.details[index].output : ""
            let full = index < line.details.count ? line.details[index].full : nil
            if tool.hasPrefix("新建日程：") {
                out.append(Keepsake(id: index, kind: .event, title: String(tool.dropFirst(5)), detail: "已加进日历", url: URL(string: "calshow://")))
            } else if tool.hasPrefix("加提醒：") {
                out.append(Keepsake(id: index, kind: .reminder, title: String(tool.dropFirst(4)), detail: "已加进提醒事项", url: URL(string: "x-apple-reminderkit://")))
            } else if tool.hasPrefix("查天气："), !output.isEmpty, !output.hasPrefix("没找到") {
                out.append(Keepsake(id: index, kind: .weather, title: String(tool.dropFirst(4)), detail: output))
            } else if tool.hasPrefix("健康："), !output.isEmpty {
                out.append(Keepsake(id: index, kind: .health, title: String(tool.dropFirst(3)), detail: output, url: URL(string: "x-apple-health://"), diff: full))
            } else if tool.hasPrefix("书案：写 ") || tool.hasPrefix("书案：改 ") {
                let path = String(tool.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let file = Workspace.resolve(path), FileManager.default.fileExists(atPath: file.path) {
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    if let kept = out.firstIndex(where: { $0.url == file }) {
                        out[kept] = Keepsake(id: out[kept].id, kind: .file, title: file.lastPathComponent, detail: desk + Workspace.relative(file) + " · 改了几次，这是最后一次", url: file, diff: full ?? out[kept].diff)
                    } else {
                        out.append(Keepsake(id: index, kind: .file, title: file.lastPathComponent, detail: desk + Workspace.relative(file) + change, url: file, diff: full))
                    }
                }
            } else if tool.hasPrefix("斗室：") || tool.hasPrefix("远山 · ") {
                let rest = tool.split(separator: "：", maxSplits: 1).last.map(String.init) ?? tool
                if ["读 ", "找 ", "搜 ", "翻看 ", "看图 ", "看后台任务", "看看后台任务", "停掉后台任务", "后台跑"].contains(where: { rest.hasPrefix($0) }) { continue }
                if rest.hasPrefix("写 ") || rest.hasPrefix("改 ") {
                    let where_ = tool.split(separator: "：", maxSplits: 1).first.map(String.init) ?? ""
                    let change = Diff.counts(in: output).map { " · −\($0.removed) +\($0.added) 行" } ?? ""
                    out.append(Keepsake(id: index, kind: .remoteFile, title: (String(rest.dropFirst(2)) as NSString).lastPathComponent, detail: String(rest.dropFirst(2)) + change, diff: full, place: where_))
                    continue
                }
                guard tool.hasPrefix("斗室：") else { continue }
                let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
                out.append(Keepsake(id: index, kind: .command, title: rest, detail: tail.isEmpty ? "（没有输出）" : tail))
            }
        }
        return out
    }
    @State private var open = Pref.traceOpen

    /// While it works: 「第 3 步：搜索 重庆天气」.
    private var liveLine: String {
        guard let current = line.tools.last else { return "沉吟" }
        return "第 \(line.tools.count) 步：" + current
    }

    /// Done: 「6 步 · 搜索、读网页、写文件 · 12 秒」.
    private var summary: String {
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
    @State private var peeking: Set<Int> = []

    /// Pages a companion opened in 远游 during these steps, newest last, each once.
    private var pages: [URL] {
        var seen: [URL] = []
        for tool in line.tools where tool.hasPrefix("远游：http") && !tool.hasSuffix("（没成功）") {
            if let url = URL(string: String(tool.dropFirst(3)).trimmingCharacters(in: .whitespaces)), !seen.contains(url) { seen.append(url) }
        }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Ink.Motion.unfold) { open.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    if line.live {
                        ProgressView().controlSize(.mini).tint(Ink.accent)
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ok)
                    }
                    Text(Words.t(line.live ? liveLine : summary))
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
        .task(id: line.live ? nil : KeepsakeInput(line: line, desk: Words.t("书案/"))) {
            guard !line.live else { keepsakes = []; return }
            let input = KeepsakeInput(line: line, desk: Words.t("书案/"))
            let job = Task.detached(priority: .utility) { Self.buildKeepsakes(input.line, desk: input.desk) }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            if !Task.isCancelled { keepsakes = result }
        }
        .animation(Ink.Motion.settle, value: line.tools.count)
        // Done: everything folds into the one line again.
        .onChange(of: line.live) { _, live in
            if !live { withAnimation(Ink.Motion.unfold) { open = Pref.traceOpen } }
        }
        if !line.live, changedFiles.count >= 2 {
            changesCard
        }
        if !line.live {
            ForEach(changedFiles.count >= 2 ? keepsakes.filter { $0.kind != .file && $0.kind != .remoteFile } : keepsakes) { item in
                Button {
                    Haptics.light()
                    switch item.kind {
                    case .file, .remoteFile:
                        if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                            diffing = DiffShow(title: item.title, place: item.displayDetail, diff: diff, url: item.url)
                        } else if let url = item.url {
                            openFile(url)
                        }
                    case .event, .reminder, .health: if let url = item.url { UIApplication.shared.open(url) }
                    case .weather: break
                    case .command: break
                    }
                } label: {
                    if item.kind == .health {
                        HealthCard(text: item.detail, format: item.diff)
                    } else if item.kind == .weather {
                        WeatherCard(text: item.detail)
                    } else {
                    HStack(alignment: .top, spacing: Ink.Space.m) {
                        Image(systemName: Self.keepsakeIcon(item.kind)).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .command ? "# " + item.title : item.title)
                                .font(item.kind == .command ? Ink.mono(Ink.Size.small, weight: .medium) : .system(size: Ink.Size.sub, weight: .medium))
                                .foregroundStyle(Ink.ink).lineLimit(2)
                            Text(item.displayDetail)
                                .font(item.kind == .command ? Ink.mono(Ink.Size.micro) : Ink.footnote)
                                .foregroundStyle(Ink.inkSoft).lineLimit(3)
                            if !Self.isDocument(item), let diff = item.diff, !diff.isEmpty {
                                // The first few changed lines, so the card shows what changed at a glance.
                                DiffText(hunk: DiffText.glance(diff), limit: 5)
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.kind != .command, item.kind != .remoteFile || item.diff != nil {
                            Image(systemName: "chevron.right").font(.system(size: Ink.Size.micro, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                        }
                    }
                    .padding(Ink.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()
                    }
                }
                .buttonStyle(PressStyle())
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
                DiffSheet(title: show.title, place: show.place, diff: show.diff, url: show.url) { url in
                    diffing = nil
                    openFile(url)
                }
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
        let parts = tool.split(separator: "：", maxSplits: 1).map(String.init)
        let name = parts.first ?? tool
        let detail = parts.count > 1 ? parts[1] : nil
        let failed = tool.hasSuffix("（没成功）")
        let more = index < line.details.count ? line.details[index] : nil
        let shown = peeking.contains(index)
        return HStack(alignment: .top, spacing: Ink.Space.m) {
            VStack(spacing: 0) {
                Image(systemName: failed ? "exclamationmark" : Self.icon(for: name))
                    .font(.system(size: Ink.Size.small, weight: .medium))
                    .foregroundStyle(failed ? Ink.stop : Ink.inkSoft)
                    .frame(width: 22, height: 22)
                if !last { Rectangle().fill(Ink.rule).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 2) }
            }
            VStack(alignment: .leading, spacing: 2) {
                // One line per step: what kind of thing, then what exactly. Time only when it was worth waiting for.
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    (Text(Words.t(Self.word(for: name))).foregroundStyle(Ink.ink).fontWeight(.medium)
                        + Text(detail.map { "  " + $0 } ?? "").foregroundStyle(Ink.inkSoft))
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
                    VStack(alignment: .leading, spacing: Ink.Space.xs) {
                        if !more.input.isEmpty, more.input != "{}" {
                            Text("交给它的").font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                            Text(Self.tidy(more.input)).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(12)
                        }
                        if let name = more.photo, let data = Disk.photo(name), let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
                                .padding(.top, 2)
                        }
                        Text("它回来的").font(Ink.footnote).foregroundStyle(Ink.inkFaint).padding(.top, 2)
                        if let hunk = Diff.hunk(in: more.output) {
                            Text(more.output.components(separatedBy: "\n").first ?? "").font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                            DiffText(hunk: hunk)
                        } else {
                            Text(more.output.isEmpty ? "（空）" : String(more.output.prefix(1500))).font(Ink.mono(Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(24)
                        }
                    }
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
    static func tidy(_ json: String) -> String {
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
        switch Words.poetic(label) {
        case "搜索": "magnifyingglass"
        case "读网页": "globe"
        case "远游": "safari"
        case "书案": "books.vertical"
        case "斗室": "terminal"
        case "所在": "location"
        case "远山": "mountain.2"
        case "递笺": "square.and.pencil"
        case "信匣": "lock.rectangle.stack"
        case "通讯录": "person.crop.circle"
        case "相册": "photo.on.rectangle"
        case "步数": "figure.walk"
        case "剪贴板": "doc.on.clipboard"
        case "打开": "arrow.up.forward.app"
        case "手机": "iphone"
        case "记住", "忘掉": "bookmark"
        case "看日历", "新建日程": "calendar"
        case "看提醒事项", "加提醒": "checklist"
        default: label.hasPrefix("约好") ? "envelope" : "wrench.and.screwdriver"
        }
    }
}
