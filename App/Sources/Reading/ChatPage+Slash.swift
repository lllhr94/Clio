import AVFoundation
import AgentKit
import CoreLocation
import Craft
import PhotosUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

extension ChatPage {
    // MARK: / and @

    /// One suggestion over the composer: a command after 「/」, a file after 「@」.
    struct Hint: Identifiable {
        let id: String
        let icon: String
        let title: String
        let note: String
        let run: () -> Void
    }

    var composerSuggestions: some View {
        let query = DraftInput.suggestion(in: draft)
        let suggestions = query.map { hints($0) } ?? []
        let source = query?.source
        return Group {
            if !suggestions.isEmpty { hintStrip(suggestions) }
        }
        .task(id: source) { await loadSuggestions(source) }
    }

    func loadSuggestions(_ source: DraftInput.Source?) async {
        switch source {
        case .skills:
            let skills = await Task.detached(priority: .userInitiated) { SkillShelf.enabled }.value
            if !Task.isCancelled { draftState.skills = skills }
        case .files:
            let job = Task.detached(priority: .userInitiated) {
                Workspace.files(under: Workspace.root, cap: 800)
                    .filter { !$0.path.hasPrefix("技能/") && !$0.path.hasSuffix(".pdf.txt") }
                    .sorted { $0.date > $1.date }
                    .map(\.path)
            }
            let paths = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            if !Task.isCancelled { draftState.files = paths }
        case nil:
            draftState.files = []
            draftState.skills = []
        }
    }

    func hints(_ query: DraftInput.Suggestion) -> [Hint] {
        let typed = query.text.lowercased()
        if query.source == .skills {
            var list: [Hint] = [
                Hint(id: "leaf", icon: "square.and.pencil", title: "/新对话", note: Words.t("另起一叶，眼下的收起来")) {
                    draft = ""
                    team.turnLeaf(chat.key)
                },
                Hint(id: "redo", icon: "arrow.clockwise", title: "/重来", note: "最后一句重新回答") {
                    draft = ""
                    chat.retry()
                },
                Hint(id: "squeeze", icon: "rectangle.compress.vertical", title: "/压缩", note: "把较早的话写成提要，省上下文") {
                    draft = ""
                    Task { _ = try? await team.compress(chat.key) }
                },
                Hint(id: "detail", icon: "square.and.arrow.up", title: "/导出", note: "看这段对话的详情，可导出成 Markdown") {
                    draft = ""
                    detailOpen = true
                },
            ]
            for item in draftState.skills where item.on {
                list.append(Hint(id: "skill-" + item.id, icon: "wand.and.stars", title: "/" + item.skill.name, note: item.skill.description) {
                    draft = "用技能「\(item.skill.name)」："
                })
            }
            return typed.isEmpty ? list : list.filter { $0.title.lowercased().contains(typed) || $0.note.lowercased().contains(typed) }
        } else {
            let all = draftState.files.lazy.filter { typed.isEmpty || $0.lowercased().contains(typed) }.prefix(6)
            return all.map { file in
                Hint(id: "file-" + file, icon: "doc", title: (file as NSString).lastPathComponent, note: Words.t("书案/") + file) {
                    if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) }
                    if !files.contains(file) { withAnimation(Ink.Motion.settle) { files.append(file) } }
                }
            }
        }
    }

    func hintStrip(_ hints: [Hint]) -> some View {
        VStack(spacing: 0) {
            ForEach(hints.prefix(6)) { hint in
                Button {
                    Haptics.tick(0.4)
                    hint.run()
                } label: {
                    HStack(spacing: Ink.Space.m) {
                        Image(systemName: hint.icon).font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hint.title).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(hint.note).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Ink.Space.xs)
        .paperCard()
        .padding(.bottom, Ink.Space.s)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    /// What the send button sends: the draft and the files picked for it.
    var outgoing: String {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (words.isEmpty && !files.isEmpty ? "看看这些文件。" : draft) + fileNote
    }

    func clearComposer() {
        pasteTask?.cancel()
        invalidatePhotoSelection()
        historyPage = nil
        draft = ""
        photos = []
        files = []
        DraftAttachments.clear(chat.key)
        following = true
        followToEnd()
    }

    func invalidatePhotoSelection() {
        attachmentRevision = UUID()
        picks = []
    }

    func addPhoto(_ data: Data, revision: UUID, selection: [PhotosPickerItem]? = nil) async -> Data? {
        guard revision == attachmentRevision, photos.count < 4 else { return nil }
        let small = await Task.detached(priority: .userInitiated) {
            Picture.shrink(data, longest: 1568)?.data
        }.value
        guard !Task.isCancelled, revision == attachmentRevision, selection == nil || selection == picks,
              photos.count < 4, let small else { return nil }
        withAnimation(Ink.Motion.settle) { photos.append(small) }
        return small
    }
}
