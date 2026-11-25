import Craft
import SwiftUI

/// 对话详情: one page for the whole conversation. On top how long it ran, how many steps, how many files it
/// changed; below, the steps in order, the files, and how full the context is.
struct ChatDetail: View {
    @ObservedObject var team: TeamModel
    let chat: ChatModel
    let title: String
    /// The companion this conversation is with; nil for a gathering.
    var bot: BotInfo? = nil
    var openCard: (() -> Void)?
    var openLeaves: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.steps
    @State private var files: [Snapshots.Kept] = []
    @State private var resolvedFiles: [String: WorkspaceFileRef] = [:]
    @State private var usage = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var sharing: ExportedChat?
    @State private var exporting = false
    @State private var exportFailed = false

    enum Tab: String, CaseIterable, Identifiable {
        case steps, files
        var id: String { rawValue }
        var title: String { self == .steps ? "轨迹" : "产出" }
    }

    private var steps: [(label: String, seconds: Int?)] {
        chat.lines.filter { $0.kind == .steps }.flatMap { line in
            line.tools.enumerated().map { index, label in
                (label, index < line.details.count ? line.details[index].seconds : nil)
            }
        }
    }

    private var minutes: Int {
        let entries = team.history(chat.key)
        guard let first = entries.first?.at, let last = entries.last?.at else { return 0 }
        return max(0, Int((last - first) / 60_000))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    hero
                    Picker("看什么", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .steps: stepList
                    case .files: fileList
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("chat.details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.export"), systemImage: "square.and.arrow.up") {
                        let name = team.title(of: chat.key) ?? title
                        exporting = true
                        Task {
                            defer { exporting = false }
                            if let url = await team.exportChat(chat.key, title: name) {
                                sharing = ExportedChat(url: url)
                            } else {
                                exportFailed = true
                            }
                        }
                    }
                    .disabled(exporting)
                }
            }
        }
        .alert("重命名对话", isPresented: $renaming) {
            TextField("对话标题", text: $renameText)
            Button(L.t("actions.cancel"), role: .cancel) {}
            Button(L.t("actions.save")) { team.rename(chat.key, to: renameText) }
        }
        .sheet(isPresented: $usage) {
            UsageSheet(team: team, key: chat.key).presentationDetents([.medium, .large])
        }
        .sheet(item: $sharing) { item in ChatShareSheet(url: item.url) }
        .alert(L.t("errors.exportChat"), isPresented: $exportFailed) {
            Button(L.t("actions.done"), role: .cancel) {}
        }
        .task {
            let kept = team.allChangedFiles(chat.key)
            files = kept
            let deskPaths = kept.filter { WorkPlace(code: $0.place) == .desk }.map(\.path)
            guard !deskPaths.isEmpty else { return }
            let resolved = await Task.detached(priority: .utility) {
                var map: [String: WorkspaceFileRef] = [:]
                for path in deskPaths {
                    if let ref = WorkspaceFileRef.resolve(path) {
                        map[path] = ref
                    }
                }
                return map
            }.value
            if !Task.isCancelled { resolvedFiles = resolved }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            if let bot, let openCard {
                companion(bot, openCard)
                Kit.rule(inset: 0)
            }
            Button {
                renameText = team.title(of: chat.key) ?? ""
                renaming = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    Text(team.title(of: chat.key) ?? title).font(Ink.serif(Ink.Size.title, bold: true)).foregroundStyle(Ink.ink).lineLimit(2)
                    Image(systemName: "pencil").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("重命名对话")
            HStack(spacing: 0) {
                stat("\(minutes)", "分钟")
                stat("\(steps.count)", "步")
                stat("\(files.count)", "个文件")
            }
            HStack(spacing: Ink.Space.s) {
                pill("用量", "chart.pie") { usage = true }
                if let openLeaves { pill(Words.t("絮语页"), "book.pages") { openLeaves(); dismiss() } }
            }
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    /// Who this conversation is with, first on the page: tap to change the name, the character, the model.
    private func companion(_ bot: BotInfo, _ open: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            open()
            dismiss()
        } label: {
            HStack(spacing: Ink.Space.m) {
                PetStill(size: 44, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(bot.name).font(.system(size: Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.ink)
                    Text("名字、性格、用哪个模型").font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                }
                Spacer(minLength: Ink.Space.s)
                Text(L.t("actions.edit")).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.accent)
                Kit.chevron
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("编辑\(bot.name)的名字、性格和模型")
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.xs / 2) {
            Text(value).font(.system(size: Ink.Size.title, weight: .semibold).monospacedDigit()).foregroundStyle(Ink.ink)
            Text(unit).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            run()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: Ink.Size.small, weight: .medium))
                .foregroundStyle(Ink.accent)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 30)
                .background(Ink.accentWash, in: .capsule)
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    @ViewBuilder
    private var stepList: some View {
        let all = steps
        if all.isEmpty {
            EmptyNote(symbol: "point.topleft.down.to.point.bottomright.curvepath", words: L.t("empty.conversationTools"))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: Ink.Space.m) {
                        Text("\(index + 1)").font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkFaint).frame(width: 24, alignment: .trailing)
                        Text(Words.t(step.label)).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(2)
                        Spacer(minLength: 0)
                        if let seconds = step.seconds { Text(Clock.said(seconds)).font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkFaint) }
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.m)
                }
            }
            .padding(.vertical, Ink.Space.xs)
            .paperCard()
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            EmptyNote(symbol: "doc.badge.ellipsis", words: L.t("empty.conversationFiles"))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    let place = WorkPlace(code: file.place)
                    let resolved = place == .desk ? resolvedFiles[file.path] : nil
                    Group {
                        if let resolved {
                            NavigationLink { StudyFile(url: resolved.url, mount: resolved.mount) } label: { fileRow(file, place: place, isNew: file.backup == nil) }
                        } else {
                            fileRow(file, place: place, isNew: file.backup == nil)
                        }
                    }
                }
            }
            .padding(.vertical, Ink.Space.xs)
            .paperCard()
        }
    }

    private func fileRow(_ file: Snapshots.Kept, place: WorkPlace, isNew: Bool) -> some View {
        RowLabel(isNew ? "doc.badge.plus" : "doc.text",
                 title: (file.path as NSString).lastPathComponent,
                 line: "\(place.title) · \(file.path)",
                 end: .value(isNew ? "新建" : "改过"))
    }
}

private struct ExportedChat: Identifiable {
    let url: URL
    var id: URL { url }
}

extension TeamModel {
    private nonisolated static let exportClockLock = NSLock()
    private nonisolated static let exportClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Only called on an export tap. Keep the current log and speaker names, then format and write them off the UI thread.
    func exportChat(_ key: String, title: String) async -> URL? {
        let entries = history(key)
        let names = Dictionary(bots.map { ($0.id, Words.t($0.name)) }, uniquingKeysWith: { first, _ in first })
        let fallback = L.t("nav.assistant")
        return await Task.detached(priority: .userInitiated) {
            let safe = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = folder.appendingPathComponent("\(safe.isEmpty ? "对话" : safe).md")
            var out = "# \(title)\n\n"
            for entry in entries where entry.note != true {
                let message = entry.message
                let time: String = {
                    Self.exportClockLock.lock()
                    defer { Self.exportClockLock.unlock() }
                    return Self.exportClockFormatter.string(from: Date(timeIntervalSince1970: entry.at / 1000))
                }()
                switch message.role {
                case .user:
                    guard !message.text.isEmpty else { continue }
                    out += "## 我 · \(time)\n\n\(message.text)\n\n"
                case .assistant:
                    let who = entry.speaker.flatMap { names[$0] } ?? fallback
                    if !message.text.isEmpty { out += "## \(who) · \(time)\n\n\(message.text)\n\n" }
                    for call in message.toolCalls { out += "> 做了：\(entry.label ?? call.name)\n\n" }
                default:
                    continue
                }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try out.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
        }.value
    }
}
