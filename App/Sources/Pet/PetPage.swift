import SwiftUI
import UniformTypeIdentifiers

/// 宠物设置: which pet is yours (it is also every portrait in Clio), whether it stands on the composer, how big,
/// quiet or not; importing your own, from a pet pack or a single picture.
struct PetPage: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var previewSince = Date()
    @State private var library = PetLibrary.shared
    @State private var importing = false
    @State private var installing = false
    @State private var notice: String?
    @State private var deleting: PetPack?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        Form {
                PaperRows {
                    Section {
                        sizePreview
                        sizeSlider
                    } header: { Text(L.t("pet.size")) } footer: {
                        Text(L.t("pet.sizeStandard"))
                    }

                    Section {
                        if library.loading || installing { ProgressView(L.t("loading.generic")) }
                        ForEach(library.packs) { pack in
                            choiceRow(id: pack.id, title: pack.name, line: [pack.author, pack.license].filter { !$0.isEmpty }.joined(separator: " · "))
                                .contextMenu {
                                    if !installing, library.canDelete(pack) {
                                        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { deleting = pack }
                                    }
                                }
                        }
                        Button {
                            importing = true
                        } label: {
                            Label("导入宠物", systemImage: "square.and.arrow.down")
                        }
                        .disabled(library.loading || installing)
                    } header: { Text(L.t("pet.choose")) } footer: {
                        Text(Words.t("选中的宠物也会出现在各处的宠物插图中。导入认三种：DSH Go、Clawd on Desk 那种宠物包（zip）；每个状态一个 GIF / APNG 打成的 zip，文件名用状态名（idle、thinking、working、done、error、sleeping……）；或者直接一张图片、一个 GIF，就是一只只会站着的宠物。长按导入的可以删掉。"))
                    }

                    Section {
                        Toggle(L.t("pet.showOnComposer"), isOn: $library.visible)
                        Toggle(L.t("pet.quietMode"), isOn: $library.quiet)
                        if let until = library.hiddenUntil, until > Date() {
                            Button("现在就出来（藏到 \(until.formatted(date: .omitted, time: .shortened))）") {
                                withAnimation(Ink.Motion.settle) { library.hiddenUntil = nil }
                            }
                        }
                    } footer: {
                        Text("关掉「站在输入框上」只是不站出来，宠物插图照常显示。别的\(L.t("chat.conversation"))做完、出错、等你确认时冒个气泡，点气泡直接过去；安静模式下只做动作。点它、连点、拖它、长按，都有反应。")
                    }
                }
            }
            .paperForm()
            .navigationTitle(L.t("pet.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .png, .gif, .webP]) { result in
                guard case .success(let url) = result else { return }
                installing = true
                Task {
                    defer { installing = false }
                    do {
                        let pack = try await library.install(url)
                        library.choice = pack.id
                        notice = "装好了：\(pack.name)"
                    } catch {
                        notice = "没装上：\(error.localizedDescription)"
                    }
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button(L.t("actions.done"), role: .cancel) { notice = nil }
            }
            .confirmationDialog("删掉「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L.t("actions.delete"), role: .destructive) {
                    if let deleting { library.delete(deleting.id) }
                    deleting = nil
                }
            } message: { Text(L.daily["errors.cannotUndo"] ?? "删除后无法恢复。") }
    }

    private var levels: [Double] { PetSize.levels(for: library.pack, displayScale: displayScale) }

    /// The size as 档位 on the one adjuster Clio uses (主人定); the preview above follows while dragging.
    private var sizeSlider: some View {
        let marks = levels
        return StopRow(
            title: L.t("pet.size"),
            value: Binding(
                get: { marks.isEmpty ? library.factor : marks[PetSize.nearest(library.factor, in: marks)] },
                set: { library.factor = $0 }
            ),
            stops: marks.map { Stop(value: $0, name: "\(Int(($0 * 100).rounded()))%") }
        )
        .disabled(marks.count < 2)
    }

    private var sizePreview: some View {
        GeometryReader { proxy in
            if let pack = library.pack {
                let mark = levels[PetSize.nearest(library.factor, in: levels)]
                let unit = PetSize.unit(for: pack, factor: mark, displayScale: displayScale,
                                        maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                SpritePet(pack: pack, anim: pack.anim(for: "idle") ?? "", since: previewSince, unit: unit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: PetSize.standardHeight * 3 + Ink.Space.m)
        .accessibilityHidden(true)
        .onChange(of: library.choice) { previewSince = Date() }
    }

    private func choiceRow(id: String, title: String, line: String?) -> some View {
        Button {
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) { library.choice = id }
        } label: {
            HStack(spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Ink.ink)
                    if let line, !line.isEmpty { Text(line).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(2) }
                }
                Spacer()
                if library.choice == id { Image(systemName: "checkmark").foregroundStyle(Ink.accent).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
