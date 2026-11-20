import Craft
import SwiftUI

/// 对话详情: one page for the whole conversation. On top how long it ran, how many steps, how many files it
/// changed; below, the steps in order, the files, and how full the context is.
struct ChatDetail: View {
    @ObservedObject var team: TeamModel
    @ObservedObject var chat: ChatModel
    let title: String
    var openCard: (() -> Void)?
    var openLeaves: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.steps
    @State private var files: [Snapshots.Kept] = []
    @State private var usage = false

    enum Tab: String, CaseIterable, Identifiable {
        case steps, files
        var id: String { rawValue }
        var title: String { self == .steps ? "轨迹" : "改动" }
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
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: exportFile(), preview: SharePreview("\(title).md")) {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $usage) {
            UsageSheet(team: team, key: chat.key).presentationDetents([.medium, .large])
        }
        .task { files = team.allChangedFiles(chat.key) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(title).font(Ink.serif(20, bold: true)).foregroundStyle(Ink.ink).lineLimit(2)
            HStack(spacing: 0) {
                stat("\(minutes)", "分钟")
                stat("\(steps.count)", "步")
                stat("\(files.count)", "个文件")
            }
            HStack(spacing: Ink.Space.s) {
                pill("用量", "chart.pie") { usage = true }
                if let openLeaves { pill(Words.t("絮语页"), "book.pages") { openLeaves(); dismiss() } }
                if let openCard { pill(Words.t("名帖"), "person.text.rectangle") { openCard(); dismiss() } }
            }
        }
        .padding(Ink.Space.l)
        .paperCard()
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(Ink.ink)
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
                        Text(step.label).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.ink).lineLimit(2)
                        Spacer(minLength: 0)
                        if let seconds = step.seconds { Text(Clock.said(seconds)).font(.system(size: Ink.Size.small).monospacedDigit()).foregroundStyle(Ink.inkFaint) }
                    }
                    .padding(.horizontal, Ink.Space.l)
                    .padding(.vertical, Ink.Space.s + 2)
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
                    let local = place == .desk ? Workspace.resolve(file.path) : nil
                    Group {
                        if let local, FileManager.default.fileExists(atPath: local.path) {
                            NavigationLink { StudyFile(url: local) } label: { fileRow(file, place: place, isNew: file.backup == nil) }
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
        HStack(spacing: Ink.Space.m) {
            Image(systemName: isNew ? "doc.badge.plus" : "doc.text").foregroundStyle(Ink.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent).font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text("\(place.title) · \(file.path)").font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(isNew ? "新建" : "改过").font(.system(size: Ink.Size.micro, weight: .medium)).foregroundStyle(Ink.inkSoft)
        }
        .padding(.horizontal, Ink.Space.l)
        .padding(.vertical, Ink.Space.s + 2)
        .contentShape(Rectangle())
    }
}

extension ChatDetail {
    /// The conversation as a Markdown file in the temporary folder: what was said, what was done; notes and
    /// tool output stay out. Never the vault.
    func exportFile() -> URL {
        let safe = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "对话" : safe).md")
        try? team.markdown(chat.key, title: title).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension TeamModel {
    func markdown(_ key: String, title: String) -> String {
        let when = DateFormatter()
        when.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n"
        for entry in history(key) where entry.note != true {
            let message = entry.message
            let time = when.string(from: Date(timeIntervalSince1970: entry.at / 1000))
            switch message.role {
            case .user:
                guard !message.text.isEmpty else { continue }
                out += "## 我 · \(time)\n\n\(message.text)\n\n"
            case .assistant:
                let who = entry.speaker.flatMap { id in bots.first(where: { $0.id == id })?.name } ?? "旅伴"
                if !message.text.isEmpty { out += "## \(Words.t(who)) · \(time)\n\n\(message.text)\n\n" }
                for call in message.toolCalls { out += "> 做了：\(entry.label ?? call.name)\n\n" }
            default:
                continue
            }
        }
        return out
    }
}
