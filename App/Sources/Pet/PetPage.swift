import SwiftUI
import UniformTypeIdentifiers

/// 宠物设置: which pet is yours (it is also every portrait in Clio), whether it stands on the composer, how big,
/// quiet or not; importing your own, from a pet pack or a single picture.
struct PetPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = PetLibrary.shared
    @State private var importing = false
    @State private var notice: String?
    @State private var deleting: PetPack?

    var body: some View {
        NavigationStack {
            Form {
                PaperRows {
                    Section {
                        preview
                            .frame(maxWidth: .infinity)
                            .frame(height: 120)
                            .listRowBackground(Ink.paperRaised)
                    }

                    Section {
                        ForEach(library.packs) { pack in
                            choiceRow(id: pack.id, title: pack.name, line: [pack.author, pack.license].filter { !$0.isEmpty }.joined(separator: " · "))
                                .contextMenu {
                                    if library.canDelete(pack) {
                                        Button(L.t("actions.delete"), systemImage: "trash", role: .destructive) { deleting = pack }
                                    }
                                }
                        }
                        Button {
                            importing = true
                        } label: {
                            Label("导入宠物", systemImage: "square.and.arrow.down")
                        }
                    } header: { Text(L.t("pet.choose")) } footer: {
                        Text("选中的这只也是旅伴的头像和各处的插图。导入认三种：DSH Go、Clawd on Desk 那种宠物包（zip）；每个状态一个 GIF / APNG 打成的 zip，文件名用状态名（idle、thinking、working、done、error、sleeping……）；或者直接一张图片、一个 GIF，就是一只只会站着的宠物。长按导入的可以删掉。")
                    }

                    Section {
                        Picker("大小", selection: $library.size) {
                            Text("小").tag("small")
                            Text("标准").tag("standard")
                            Text("大").tag("large")
                            Text("自定义").tag("custom")
                        }
                        .pickerStyle(.segmented)
                        if library.size == "custom" {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L.t("pet.sizeReference"))
                                    Spacer()
                                    Text("\(Int(library.custom * 100))%").foregroundStyle(Ink.inkSoft).monospacedDigit()
                                }
                                Slider(value: $library.custom, in: 0.5...3, step: 0.05)
                            }
                        }
                    } header: { Text(L.t("pet.size")) }

                    Section {
                        Toggle(L.t("pet.showOnComposer"), isOn: $library.visible)
                        Toggle(L.t("pet.quietMode"), isOn: $library.quiet)
                        if let until = library.hiddenUntil, until > Date() {
                            Button("现在就出来（藏到 \(until.formatted(date: .omitted, time: .shortened))）") {
                                withAnimation(Ink.Motion.settle) { library.hiddenUntil = nil }
                            }
                        }
                    } footer: {
                        Text("关掉「站在输入框上」只是不站出来，头像和插图还是它。别的\(L.t("chat.conversation"))做完、出错、等你确认时冒个气泡，点气泡直接过去；安静模式下只做动作。点它、连点、拖它、长按，都有反应。")
                    }
                }
            }
            .paperForm()
            .navigationTitle(L.t("pet.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .png, .gif, .webP]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let pack = try library.install(url)
                    library.choice = pack.id
                    notice = "装好了：\(pack.name)"
                } catch {
                    notice = "没装上：\(error.localizedDescription)"
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
    }

    @ViewBuilder
    private var preview: some View {
        if let pack = library.pack {
            SpritePet(pack: pack, anim: pack.anim(for: "idle") ?? "", since: Date(), bodyHeight: CGFloat(30 * library.factor) * UIScale.factor)
        }
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
