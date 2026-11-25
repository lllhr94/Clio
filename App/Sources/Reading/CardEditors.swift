import SwiftUI
import PhotosUI

// MARK: Shared pieces

/// The small serif label above a field.
struct FieldTitle: View {
    let text: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
            Text(text).font(.system(size: Ink.Size.small, weight: .medium)).foregroundStyle(Ink.inkSoft)
                .accessibilityAddTraits(.isHeader)
            if let note { Text(note).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint) }
        }
        .padding(.horizontal, Ink.Space.l)
    }
}

extension View {
    /// A text field sitting on raised paper.
    func paperField(height: CGFloat? = 50) -> some View {
        self
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, height == nil ? Ink.Space.m : 0)
            .frame(minHeight: height)
            .paperCard(radius: Ink.Radius.field)
    }
}

// MARK: 名帖

/// A companion's card to write: what to call it, one line about it, who it is and how it talks, its model and its ground.
struct BotEditor: View {
    @ObservedObject var team: TeamModel
    let bot: BotInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var role: String
    @State private var tint: String
    /// "" follows the default model.
    @State private var model: String
    @State private var instructions: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var naming: Bool
    /// nil = the pet picked in 宠物设置; "pet:<id>" = a pet of its own; "photo" = a picture from 相册.
    @State private var face: String?
    /// A picture just picked, not saved yet.
    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var temper: Temper
    @State private var style: SpeechStyle
    /// "" is the first character of its name.
    @State private var seal: String

    /// Ways to begin a card, for when a blank page is hard.
    private static var samples: [(title: String, role: String, words: String)] {
        [
            ("温和管家", "照看日程和琐事", "说话温和、简洁。替我记着日程、提醒和待办；能用手机里的本事就直接去做，做之前简单说一声。"),
            ("研究员", "查资料、写总结", "严谨，先查证再下结论，给出处。回答先给结论，再分点说理由；不确定就直说，不要编。"),
            ("写作伙伴", "改文章、出点子", "文字有画面感，擅长润色和起标题。改稿时先说改了什么、为什么，保留我的语气。"),
            ("代码搭子", "写代码、跑脚本", Words.t("务实。能在斗室里跑的先跑一遍再给我；代码给完整可运行的，解释简短。")),
            ("直言的朋友", "说真话的朋友", "说话直接，带点幽默，不客套。我的想法有漏洞时直接指出来，再给更好的办法。"),
        ]
    }

    init(team: TeamModel, bot: BotInfo?) {
        self.team = team
        self.bot = bot
        _name = State(initialValue: bot?.name ?? "")
        _role = State(initialValue: bot?.role ?? "")
        _tint = State(initialValue: bot?.color.flatMap { key in Ink.tints.contains { $0.key == key } ? key : nil } ?? "dai")
        _model = State(initialValue: bot?.model ?? "")
        _instructions = State(initialValue: bot?.instructions ?? "")
        _face = State(initialValue: bot?.avatar)
        _temper = State(initialValue: Temper.of(bot))
        _style = State(initialValue: SpeechStyle.of(bot))
        _seal = State(initialValue: bot?.seal ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && !busy }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        preview

                        faces

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: "称呼")
                            TextField("比如：团子", text: $name)
                                .font(Ink.serif(Ink.Size.body, bold: true))
                                .focused($naming)
                                .submitLabel(.done)
                                .paperField()
                        }

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: "一句话简介", note: Words.t("写在名帖上，案头和雅集里都会看到"))
                            TextField("比如：查资料、写总结", text: $role)
                                .font(.system(size: Ink.Size.body))
                                .submitLabel(.done)
                                .paperField()
                        }

                        temperPicker

                        stylePicker

                        sealField

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: "设定", note: "它是谁、怎么说话、擅长什么。写得越具体，越像它自己；和性格有出入时以这里为准")
                            ScrollView(.horizontal) {
                                HStack(spacing: Ink.Space.s) {
                                    ForEach(Self.samples, id: \.title) { sample in
                                        Button {
                                            Haptics.tick(0.5)
                                            withAnimation(Ink.Motion.settle) {
                                                instructions = sample.words
                                                if role.trimmingCharacters(in: .whitespaces).isEmpty { role = sample.role }
                                            }
                                        } label: {
                                            Text(sample.title)
                                                .font(.system(size: Ink.Size.small, weight: .medium))
                                                .foregroundStyle(Ink.accent)
                                                .padding(.horizontal, Ink.Space.m)
                                                .frame(height: 30)
                                                .background(Ink.accentWash, in: .capsule)
                                        }
                                        .buttonStyle(PressStyle(haptic: false))
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            TextField("比如：说话温柔，爱打比方；擅长做饭，会根据冰箱里有的东西出主意。", text: $instructions, axis: .vertical)
                                .font(.system(size: Ink.Size.body))
                                .lineLimit(4...12)
                                .paperField(height: nil)
                        }

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            let activeOwnModel = (!model.isEmpty && team.resolveActive(model) != nil) ? model : nil
                            FieldTitle(text: "默认模型", note: Words.t("某一段絮语还能在顶栏另选"))
                            Menu {
                                Button {
                                    model = ""
                                } label: {
                                    if activeOwnModel == nil { Label("跟全局默认走", systemImage: "checkmark") } else { Text("跟全局默认走") }
                                }
                                ModelChoices(team: team, current: activeOwnModel) { ref in
                                    model = ref
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkle").foregroundStyle(Ink.accent)
                                    Text(activeOwnModel == nil ? "跟全局默认走（\(team.modelTitle(team.settings.defaultModel))）" : team.modelTitle(activeOwnModel))
                                        .font(.system(size: Ink.Size.body))
                                        .foregroundStyle(Ink.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkFaint)
                                }
                                .paperField()
                            }
                            .disabled(team.models.isEmpty)
                        }

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: "底色")
                            HStack(spacing: Ink.Space.m) {
                                ForEach(Ink.tints, id: \.key) { item in
                                    Button {
                                        Haptics.tick(0.5)
                                        withAnimation(Ink.Motion.press) { tint = item.key }
                                    } label: {
                                        Text(item.title)
                                            .font(Ink.serif(Ink.Size.sub, bold: tint == item.key))
                                            .foregroundStyle(Ink.ink)
                                            .frame(width: 44, height: 44)
                                            .background(item.color, in: .circle)
                                            .overlay(Circle().strokeBorder(tint == item.key ? Ink.accent : Ink.rule, lineWidth: tint == item.key ? 2 : 1))
                                            .scaleEffect(tint == item.key ? 1.08 : 1)
                                    }
                                    .buttonStyle(TapStyle())
                                    .accessibilityLabel(item.title)
                                }
                            }
                        }

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(Ink.secondary)
                                .foregroundStyle(Ink.stop)
                        }

                        if let bot {
                            VStack(spacing: Ink.Space.m) {
                                ShareLink(item: NameCardTransfer(bot: bot), preview: SharePreview(bot.name)) {
                                    Label(Words.t("把名帖递出去"), systemImage: "square.and.arrow.up")
                                        .font(.system(size: Ink.Size.sub, weight: .medium))
                                        .foregroundStyle(Ink.accent)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .paperCard()
                                }
                                if !team.isMain(bot) {
                                    Button(Words.t("送别这位旅伴")) { confirmingDelete = true }
                                        .font(.system(size: Ink.Size.sub, weight: .medium))
                                        .foregroundStyle(Ink.stop)
                                        .frame(height: 40)
                                        .disabled(busy)
                                }
                            }
                            .padding(.top, Ink.Space.s)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
            .navigationTitle(bot == nil ? L.t("organize.newProfileCard") : L.t("organize.profileCard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) {
                        Haptics.light()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(bot == nil ? "请它入座" : "存好") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(Words.t("送别\(bot?.name ?? "")？它和你的絮语、收起的旧叶会一起删掉，不能恢复。"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("送别", role: .destructive) { if let bot { remove(bot) } }
                Button("再想想", role: .cancel) {}
            }
        }
        .onAppear { if bot == nil { naming = true } }
    }

    /// 性格: four cards, two by two, each with its mark and one line.
    private var temperPicker: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: L.t("companion.temper"), note: "决定它怎么想、开口前心里写什么")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Ink.Space.s), GridItem(.flexible(), spacing: Ink.Space.s)], spacing: Ink.Space.s) {
                ForEach(Temper.allCases) { option in
                    let picked = temper == option
                    Button {
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.press) { temper = option }
                    } label: {
                        VStack(alignment: .leading, spacing: Ink.Space.xs) {
                            HStack(spacing: Ink.Space.s) {
                                Text(option.symbol).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.accent)
                                Text(option.title).font(Ink.mark(Ink.Size.body, bold: true)).foregroundStyle(Ink.ink)
                                Spacer(minLength: 0)
                                if picked { Image(systemName: "checkmark").font(.system(size: Ink.Size.small, weight: .bold)).foregroundStyle(Ink.accent) }
                            }
                            Text(option.line).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(2)
                            if let block = option.blockName {
                                Text("开口前写「\(block)」").font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                            } else {
                                Text("不写心里话").font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                            }
                        }
                        .padding(Ink.Space.m)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .background(picked ? Ink.accentWash : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(picked ? Ink.accent : Ink.rule, lineWidth: picked ? 1.5 : 1))
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityLabel("\(option.title)，\(option.line)")
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
    }

    /// 说话风格: four capsules and a bubble saying the same thing in the chosen way.
    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: "说话风格", note: "长短和口气，和性格叠在一起")
            HStack(spacing: Ink.Space.s) {
                ForEach(SpeechStyle.allCases) { option in
                    let picked = style == option
                    Button {
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { style = option }
                    } label: {
                        Text(option.title)
                            .font(.system(size: Ink.Size.small, weight: picked ? .semibold : .medium))
                            .foregroundStyle(picked ? Ink.paper : Ink.ink)
                            .padding(.horizontal, Ink.Space.m)
                            .frame(height: 32)
                            .background(picked ? Ink.ink : Ink.paperRaised, in: .capsule)
                            .overlay(Capsule().strokeBorder(picked ? .clear : Ink.rule, lineWidth: 1))
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
            .padding(.horizontal, Ink.Space.xs)
            // The same news, as this companion would say it.
            HStack(alignment: .top, spacing: Ink.Space.s) {
                PetStill(size: 28, wash: Ink.wash(named: tint), avatar: true, bot: bot, photo: face == "photo" ? photo : nil, face: .some(face))
                Text(style.sample)
                    .font(Ink.reading)
                    .foregroundStyle(Ink.ink)
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .background(Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .contentTransition(.opacity)
                    .id(style)
                    .transition(.opacity)
            }
            .padding(.horizontal, Ink.Space.xs)
        }
    }

    /// 朱印: the character on its seal, first of its name unless another is written.
    private var sealField: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: "朱印", note: Words.t("盖在名帖落款上；默认是名字的第一个字"))
            HStack(spacing: Ink.Space.m) {
                ClioSeal(size: 44, tilt: -3, character: sealShown)
                TextField(String(trimmed.first.map(String.init) ?? "克"), text: $seal)
                    .font(Ink.mark(Ink.Size.title))
                    .frame(width: 60)
                    .paperField()
                    .onChange(of: seal) { _, typed in
                        if typed.count > 1 { seal = String(typed.suffix(1)) }
                    }
                Text("只取一个字").font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Ink.Space.xs)
        }
    }

    private var sealShown: String {
        if let first = seal.trimmingCharacters(in: .whitespaces).first { return String(first) }
        return trimmed.first.map(String.init) ?? "克"
    }

    /// 头像: the default pet, a pet of its own, or a photo.
    private var faces: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            FieldTitle(text: "头像", note: "选一只宠物的话，和它聊天时站在输入框上的也是这只")
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.m) {
                    faceChoice(nil, title: "默认") {
                        PetStill(size: 52, wash: Ink.wash(named: tint), avatar: true, face: .some(nil))
                    }
                    ForEach(PetLibrary.shared.packs, id: \.id) { pack in
                        faceChoice("pet:\(pack.id)", title: pack.name) {
                            PetStill(size: 52, wash: Ink.wash(named: tint), avatar: true, face: .some("pet:\(pack.id)"))
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        faceLabel(picked: face == "photo", title: "相册") {
                            photoFace
                        }
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityLabel("从相册选一张")
                }
                .padding(.vertical, Ink.Space.xs)
            }
            .scrollIndicators(.hidden)
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let picture = UIImage(data: data) {
                    photo = picture
                    withAnimation(Ink.Motion.press) { face = "photo" }
                }
            }
        }
    }

    private func pickFace(_ value: String?) {
        Haptics.tick(0.5)
        withAnimation(Ink.Motion.press) { face = value }
    }

    @ViewBuilder
    private func faceItem(_ title: String, picked: Bool) -> some View {
        if picked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder
    private var photoFace: some View {
        if let shown = photo ?? (bot?.avatar == "photo" ? bot.flatMap { Avatars.image($0.id) } : nil) {
            Image(uiImage: shown).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(Circle())
        } else {
            Image(systemName: "photo")
                .font(.system(size: Ink.Size.body, weight: .medium))
                .foregroundStyle(Ink.inkSoft)
                .frame(width: 52, height: 52)
                .background(Ink.paperRaised, in: .circle)
        }
    }

    private func faceChoice<Face: View>(_ value: String?, title: String, @ViewBuilder face shown: () -> Face) -> some View {
        Button {
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.press) { face = value }
        } label: {
            faceLabel(picked: face == value, title: title, shown)
        }
        .buttonStyle(TapStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(face == value ? .isSelected : [])
    }

    private func faceLabel<Face: View>(picked: Bool, title: String, @ViewBuilder _ shown: () -> Face) -> some View {
        VStack(spacing: Ink.Space.xs) {
            shown()
                .overlay(Circle().strokeBorder(picked ? Ink.accent : Ink.rule, lineWidth: picked ? 2 : 1))
            Text(title)
                .font(.system(size: Ink.Size.micro, weight: picked ? .semibold : .regular))
                .foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                .lineLimit(1)
                .frame(width: 60)
        }
    }

    /// The card as it will look.
    private var preview: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Ink.Space.l) {
                // Tap the face itself to change it: the obvious place to look.
                Menu {
                    Button { pickFace(nil) } label: { faceItem("默认（跟宠物设置走）", picked: face == nil) }
                    ForEach(PetLibrary.shared.packs, id: \.id) { pack in
                        Button { pickFace("pet:\(pack.id)") } label: { faceItem(pack.name, picked: face == "pet:\(pack.id)") }
                    }
                    Button { choosingPhoto = true } label: { Label("从相册选一张", systemImage: "photo") }
                } label: {
                    PetStill(size: 72, wash: Ink.wash(named: tint), avatar: true, bot: bot, photo: face == "photo" ? photo : nil, face: .some(face))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil")
                                .font(.system(size: Ink.Size.micro, weight: .bold))
                                .foregroundStyle(Ink.paper)
                                .frame(width: 22, height: 22)
                                .background(Ink.accent, in: .circle)
                                .overlay(Circle().strokeBorder(Ink.paper, lineWidth: 2))
                        }
                }
                .accessibilityLabel("换头像")
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(trimmed.isEmpty ? "未署名" : trimmed)
                        .font(Ink.serif(Ink.Size.title, bold: true))
                        .foregroundStyle(trimmed.isEmpty ? Ink.inkFaint : Ink.ink)
                        .lineLimit(1)
                    Text(role.isEmpty ? "一句话简介" : role)
                        .font(Ink.secondary)
                        .foregroundStyle(role.isEmpty ? Ink.inkFaint : Ink.inkSoft)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(Ink.Space.l)
            Rectangle().fill(Ink.rule).frame(height: 1)
            HStack {
                Text(instructions.isEmpty ? "还没写设定" : instructions)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .lineLimit(2)
                Spacer(minLength: Ink.Space.m)
                Text(Words.t("Clio · 名帖")).font(Ink.serif(Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
            }
            .padding(.horizontal, Ink.Space.l)
            .padding(.vertical, Ink.Space.m)
        }
        .background(Ink.wash(named: tint).opacity(0.35))
        .paperCard()
        .animation(Ink.Motion.unfold, value: tint)
    }

    private static func title(_ model: ModelInfo) -> String {
        let name = model.name?.isEmpty == false ? model.name! : model.ref
        if let provider = model.providerName, !provider.isEmpty { return "\(name) · \(provider)" }
        return name
    }

    private func save() {
        guard canSave else { return }
        busy = true
        error = nil
        Task {
            do {
                // A photo is kept under the companion's id, so a new one is saved first to learn it.
                let chosen = face
                if chosen == "photo", let photo, let known = bot?.id { Avatars.save(photo, for: known) }
                let id = try await team.saveBot(id: bot?.id, name: trimmed, role: role.trimmingCharacters(in: .whitespacesAndNewlines), color: tint, model: model,
                                                instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines), avatar: chosen ?? "",
                                                temper: temper.rawValue, style: style.rawValue, seal: seal.trimmingCharacters(in: .whitespaces))
                if chosen == "photo", let photo, bot == nil { Avatars.save(photo, for: id) }
                if chosen != "photo", bot?.avatar == "photo" { Avatars.forget(id) }
                Haptics.thud()
                dismiss()
            } catch {
                busy = false
                Haptics.lock()
                self.error = "没存上：\(error.localizedDescription)"
            }
        }
    }

    private func remove(_ bot: BotInfo) {
        busy = true
        error = nil
        Task {
            do {
                try await team.deleteBot(bot.id)
                Haptics.lock()
                dismiss()
            } catch {
                busy = false
                self.error = "没删掉：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: 雅集

/// A gathering to set up: its name, who sits in, and in what order they speak.
struct RoomEditor: View {
    @ObservedObject var team: TeamModel
    var room: RoomInfo?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// In speaking order.
    @State private var members: [String] = []
    @State private var confirmingDelete = false

    private var canSave: Bool { members.count >= 2 }

    var body: some View {
        NavigationStack {
            ZStack {
                Ink.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.xl) {
                        Text(Words.t("几位旅伴轮流接话，彼此听得见"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: Words.t("雅集的名字"), note: Words.t("不填就用旅伴们的名字"))
                            TextField("比如：周末去哪玩", text: $name)
                                .font(Ink.serif(Ink.Size.body, bold: true))
                                .paperField()
                        }

                        VStack(alignment: .leading, spacing: Ink.Space.s) {
                            FieldTitle(text: "请谁入座", note: "至少两位。点选的先后，就是接话的顺序")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Ink.Space.m), count: 3), spacing: Ink.Space.m) {
                                ForEach(team.bots) { bot in seat(bot) }
                            }
                        }

                        if members.count >= 2 {
                            VStack(alignment: .leading, spacing: Ink.Space.s) {
                                FieldTitle(text: "接话顺序")
                                Text(members.compactMap { id in team.bots.first { $0.id == id }?.name }.joined(separator: "  →  "))
                                    .font(Ink.reading)
                                    .foregroundStyle(Ink.ink)
                                    .padding(Ink.Space.l)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .paperCard()
                            }
                            .transition(.opacity)
                        }

                        if room != nil {
                            Button(Words.t("散了这个雅集")) { confirmingDelete = true }
                                .font(.system(size: Ink.Size.sub, weight: .medium))
                                .foregroundStyle(Ink.stop)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                    }
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.vertical, Ink.Space.l)
                    .animation(Ink.Motion.settle, value: members)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(room == nil ? L.t("chat.newGroup") : L.t("nav.groupChat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(room == nil ? "开席" : "存好") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(Words.t("散了「\(room?.name ?? "")」？雅集里的絮语会一起删掉。"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("散了", role: .destructive) {
                    if let room { team.deleteRoom(room.id) }
                    dismiss()
                }
                Button("再想想", role: .cancel) {}
            }
        }
        .onAppear {
            if let room {
                name = room.name
                members = room.members ?? []
            }
        }
    }

    private func seat(_ bot: BotInfo) -> some View {
        let order = members.firstIndex(of: bot.id)
        return Button {
            Haptics.tick(0.6)
            if let order { members.remove(at: order) } else { members.append(bot.id) }
        } label: {
            VStack(spacing: Ink.Space.s) {
                ZStack(alignment: .topTrailing) {
                    PetStill(size: 56, wash: Ink.wash(for: bot), avatar: true, bot: bot)
                        .opacity(order == nil ? 0.5 : 1)
                    if let order {
                        Text("\(order + 1)")
                            .font(.system(size: Ink.Size.small, weight: .bold))
                            .foregroundStyle(Ink.paper)
                            .frame(width: 20, height: 20)
                            .background(Ink.accent, in: .circle)
                            .offset(x: 6, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(bot.name).font(.system(size: Ink.Size.sub, weight: .semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(bot.role ?? "").font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Ink.Space.m)
            .background(order == nil ? Ink.paper : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(order == nil ? Ink.rule : Ink.accent.opacity(0.6), lineWidth: order == nil ? 1 : 1.5))
        }
        .buttonStyle(PressStyle(haptic: false))
    }

    private func save() {
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = members.compactMap { id in team.bots.first { $0.id == id }?.name }
        let title = given.isEmpty ? names.joined(separator: "、") : given
        if let room {
            team.updateRoom(room.id, name: title, members: members)
        } else {
            team.createRoom(name: title, members: members)
        }
        Haptics.thud()
        dismiss()
    }
}
