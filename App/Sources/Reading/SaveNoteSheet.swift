import SwiftUI

/// Saves a reply as a Markdown note into 书案 or any mounted external folder (e.g. Obsidian / iCloud Drive).
struct SaveNoteSheet: View {
    let text: String
    let question: String?
    let sender: String
    var onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveNote.destination") private var savedDestination = "desk"
    @AppStorage("saveNote.includeHeader") private var includeHeader = false

    @State private var mounts: [MountedFolder] = []
    @State private var destinationID = "desk"
    @State private var subfolder = ""
    @State private var fileName = ""
    @State private var saving = false
    @State private var errorText: String?

    private struct Destination: Identifiable, Equatable {
        let id: String
        let title: String
        let baseRelative: String
        let icon: String
        let tint: Color
    }

    private var destinations: [Destination] {
        var list: [Destination] = [
            Destination(
                id: "desk",
                title: Words.t("书案 · 笔记"),
                baseRelative: "笔记",
                icon: "books.vertical",
                tint: Ink.Tile.mo
            )
        ]
        for mount in mounts {
            list.append(Destination(
                id: "mount:\(mount.id)",
                title: mount.name,
                baseRelative: "\(MountedFolders.virtualFolder)/\(mount.name)",
                icon: "link",
                tint: Ink.Tile.dai
            ))
        }
        return list
    }

    private var activeDestination: Destination {
        destinations.first(where: { $0.id == destinationID }) ?? destinations[0]
    }

    private var previewPath: String {
        let relative = buildRelativePath(fileStem: cleanFileName(fileName))
        return Words.t("书案/") + relative
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.xl) {
                    destinationSection
                    fileSection
                    optionsSection
                    if let errorText {
                        errorCard(errorText)
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("存成笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.save")) { saveNote() }
                        .fontWeight(.semibold)
                        .disabled(saving || cleanFileName(fileName).isEmpty)
                }
            }
            .task { await prepare() }
            .onChange(of: destinationID) { _, next in
                savedDestination = next
                subfolder = UserDefaults.standard.string(forKey: Self.subfolderKey(for: next)) ?? ""
            }
        }
    }

    // MARK: Sections

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("存到哪里")
            VStack(spacing: 0) {
                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, dest in
                    if index > 0 { Kit.divider }
                    destinationRow(dest)
                }
            }
            .paperCard()
            if mounts.isEmpty {
                Text(Words.t("在书案里挂载 Obsidian 或 iCloud 文件夹后，这里就可以一键存进去。"))
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func destinationRow(_ dest: Destination) -> some View {
        let isSelected = dest.id == activeDestination.id
        return Button {
            Haptics.tick(0.4)
            destinationID = dest.id
            errorText = nil
        } label: {
            HStack(spacing: Ink.Space.m) {
                IconBadge(dest.icon, tint: dest.tint)
                VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                    Text(dest.title)
                        .font(.system(size: Ink.Size.body, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Ink.ink)
                    Text(Words.t("书案/") + dest.baseRelative)
                        .font(Ink.mono(Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: Ink.Space.s)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Ink.Size.sub, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
            .frame(minHeight: Kit.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("文件位置")
            VStack(alignment: .leading, spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text("文件名")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField("笔记标题", text: $fileName)
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(Ink.ink)
                        .submitLabel(.done)
                }
                Kit.rule(inset: 0)
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text("子文件夹（可选，例如 Inbox 或 Clio）")
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                    TextField("留空直接存在根目录", text: $subfolder)
                        .font(.system(size: Ink.Size.sub))
                        .foregroundStyle(Ink.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Kit.rule(inset: 0)
                Text(previewPath)
                    .font(Ink.mono(Ink.Size.small))
                    .foregroundStyle(Ink.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Ink.Space.l)
            .paperCard()
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            SectionTitle("内容格式")
            Toggle("开头附上日期与提问", isOn: $includeHeader)
                .font(.system(size: Ink.Size.body))
                .foregroundStyle(Ink.ink)
                .tint(Ink.accent)
                .padding(.horizontal, Ink.Space.l)
                .frame(minHeight: Kit.rowHeight)
                .paperCard()
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Ink.Space.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Ink.stop)
            Text(message)
                .font(.system(size: Ink.Size.small))
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Space.l)
        .background(Ink.stop.opacity(0.08), in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
    }

    // MARK: Actions

    private func prepare() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            MountedFolders.all(fresh: true)
        }.value
        mounts = loaded
        if destinations.contains(where: { $0.id == savedDestination }) {
            destinationID = savedDestination
        } else {
            destinationID = "desk"
        }
        subfolder = UserDefaults.standard.string(forKey: Self.subfolderKey(for: destinationID)) ?? ""
        if fileName.isEmpty {
            fileName = Self.suggestTitle(from: text, question: question)
        }
    }

    private func saveNote() {
        let stem = cleanFileName(fileName)
        guard !stem.isEmpty, !saving else { return }
        saving = true
        errorText = nil

        let chosenDestID = activeDestination.id
        let cleanSub = cleanSubfolder(subfolder)
        if cleanSub.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.subfolderKey(for: chosenDestID))
        } else {
            UserDefaults.standard.set(cleanSub, forKey: Self.subfolderKey(for: chosenDestID))
        }

        let base = activeDestination.baseRelative
        let body = buildMarkdown()
        Task {
            do {
                let savedPath = try await Task.detached(priority: .userInitiated) {
                    try Self.writeUnique(base: base, subfolder: cleanSub, fileName: stem, content: body)
                }.value
                Haptics.thud()
                onSaved(savedPath)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                Haptics.lock()
            }
            saving = false
        }
    }

    // MARK: Helpers

    private static func subfolderKey(for destinationID: String) -> String {
        "saveNote.sub." + destinationID
    }

    private func buildRelativePath(fileStem: String) -> String {
        let sub = cleanSubfolder(subfolder)
        let finalName = Self.ensureExtension(fileStem.isEmpty ? "笔记" : fileStem)
        if sub.isEmpty {
            return "\(activeDestination.baseRelative)/\(finalName)"
        }
        return "\(activeDestination.baseRelative)/\(sub)/\(finalName)"
    }

    private func buildMarkdown() -> String {
        let trimmedBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeHeader else { return trimmedBody + "\n" }
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        var lines: [String] = ["---", "date: \(stamp)", "from: \(sender)", "---", ""]
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let quoted = q.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            lines.append(quoted)
            lines.append("")
        }
        lines.append(trimmedBody)
        return lines.joined(separator: "\n") + "\n"
    }

    private func cleanFileName(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: bad)
        let joined = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = joined.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(64))
    }

    private func cleanSubfolder(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "\\:*?\"<>|\n\r\t")
        return raw
            .split(separator: "/")
            .map { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: bad)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    nonisolated private static func ensureExtension(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt") {
            return name
        }
        return name + ".md"
    }

    /// Writes atomically and appends ` 2`, ` 3`, ... if a file with the same name already exists.
    nonisolated private static func writeUnique(base: String, subfolder: String, fileName: String, content: String) throws -> String {
        let full = ensureExtension(fileName)
        let ext = (full as NSString).pathExtension
        let stem = (full as NSString).deletingPathExtension
        let folder = subfolder.isEmpty ? base : "\(base)/\(subfolder)"

        var candidate = "\(folder)/\(full)"
        var suffix = 2
        while fileExists(at: candidate) && suffix < 100 {
            candidate = "\(folder)/\(stem) \(suffix).\(ext)"
            suffix += 1
        }
        try Workspace.writeBytes(candidate, data: Data(content.utf8))
        return candidate
    }

    nonisolated private static func fileExists(at relativePath: String) -> Bool {
        guard let target = try? Workspace.parse(relativePath) else { return false }
        switch target {
        case .desk(let url, _):
            return FileManager.default.fileExists(atPath: url.path)
        case .mountsRoot:
            return false
        case .mounted(let mount, let inner, _):
            guard !inner.isEmpty else { return false }
            return (try? MountedFolders.withAccess(mount, innerParts: inner) { _, url in
                FileManager.default.fileExists(atPath: url.path)
            }) ?? false
        }
    }

    private static func suggestTitle(from body: String, question: String?) -> String {
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let heading = lines.first(where: { $0.hasPrefix("#") }) {
            let cleaned = heading.drop(while: { $0 == "#" || $0 == " " })
            let candidate = stripMarkdown(String(cleaned))
            if !candidate.isEmpty { return String(candidate.prefix(36)) }
        }
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let first = q.components(separatedBy: "\n").first ?? q
            let candidate = stripMarkdown(first)
            if !candidate.isEmpty { return String(candidate.prefix(36)) }
        }
        if let first = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("```") }) {
            let candidate = stripMarkdown(first)
            if !candidate.isEmpty { return String(candidate.prefix(36)) }
        }
        let stamp = Date().formatted(.iso8601.year().month().day())
        return "笔记-\(stamp)"
    }

    private static func stripMarkdown(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "*_`~[]()/#\\:*?\"<>|")
        let stripped = raw.components(separatedBy: bad).joined()
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
