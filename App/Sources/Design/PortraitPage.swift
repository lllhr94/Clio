import PhotosUI
import SwiftUI

/// 形象: put a portrait together from swappable parts.
struct PortraitPage: View {
    @State private var persona = Persona.stored
    @Environment(\.dismiss) private var dismiss
    @State private var pose: WhalePose = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                HStack {
                    Text("形象")
                        .font(Ink.display)
                        .foregroundStyle(Ink.ink)
                    Spacer()
                    Button("好了") { dismiss() }
                        .font(Ink.label)
                        .foregroundStyle(Ink.accent)
                }
                .padding(.top, Ink.Space.xl)
                Text("每一样都能换")
                    .font(Ink.secondary)
                    .foregroundStyle(Ink.inkSoft)

                VStack(spacing: Ink.Space.l) {
                    Whale(size: 144, pose: pose, persona: persona)
                        .animation(Ink.Motion.unfold, value: persona)
                    HStack(spacing: Ink.Space.s) {
                        ForEach(WhalePose.allCases, id: \.self) { item in
                            chip(item.word, picked: pose == item) { pose = item }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Ink.Space.xl)
                .paperCard()

                // The figures to pick from, each shown as itself, then pictures of your own.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Ink.Space.m) {
                        ForEach(Persona.Kind.figures, id: \.self) { kind in
                            swatch(kind.word, picked: persona.kind == kind, preview: with { $0.kind = kind }) { persona.kind = kind }
                        }
                        chip("画像", picked: persona.kind == .picture) { persona.kind = .picture }
                    }
                }

                if persona.kind == .picture {
                    VStack(alignment: .leading, spacing: Ink.Space.m) {
                        Text("每个姿态放一张图").font(Ink.readingBold).foregroundStyle(Ink.ink)
                        Text(Words.t("只放闲坐一张也行，透明底最好"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                        HStack(spacing: Ink.Space.m) {
                            ForEach(WhalePose.allCases, id: \.self) { slot in
                                PictureSlot(pose: slot, persona: $persona)
                            }
                        }
                    }
                }

                part("底色") {
                    ForEach(0..<Persona.washNames.count, id: \.self) { index in
                        swatch(Persona.washNames[index], picked: persona.wash == index, preview: with { $0.wash = index }) { persona.wash = index }
                    }
                }
                part("画框") {
                    ForEach(Persona.Frame.allCases, id: \.self) { frame in
                        swatch(frame.word, picked: persona.frame == frame, preview: with { $0.frame = frame }) { persona.frame = frame }
                    }
                }

                if persona.kind.drawn {
                if persona.kind == .whale {
                part("轮廓") {
                    ForEach(0..<WhaleLook.looks.count, id: \.self) { index in
                        swatch(WhaleLook.names[index], picked: persona.outline == index, preview: with { $0.outline = index }) { persona.outline = index }
                    }
                }
                }
                part("墨色") {
                    ForEach(0..<Persona.tones.count, id: \.self) { index in
                        swatch(Persona.tones[index].name, picked: persona.tone == index, preview: with { $0.tone = index }) { persona.tone = index }
                    }
                }
                part("饰物") {
                    ForEach(Persona.Charm.allCases, id: \.self) { charm in
                        swatch(charm.word, picked: persona.charm == charm, preview: with { $0.charm = charm }) { persona.charm = charm }
                    }
                }
                }

                Text("颜色").font(Ink.title).foregroundStyle(Ink.ink).padding(.top, Ink.Space.s)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Ink.Space.s), count: 4), spacing: Ink.Space.s) {
                    color("纸", Ink.paper)
                    color("卡片", Ink.paperRaised)
                    color("我的话", Ink.mine)
                    color("细线", Ink.rule)
                    color("墨", Ink.ink)
                    color("淡墨", Ink.inkSoft)
                    color("黛蓝", Ink.accent)
                    color("蓝晕", Ink.accentWash)
                }

                Text(Ink.hasSongti ? "阅读字体：宋体，已找到。" : "阅读字体：没找到宋体，现在用的是系统衬线体。请把这一行截图给我。")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.hasSongti ? Ink.inkSoft : Ink.stop)
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.huge)
        }
        .scrollIndicators(.hidden)
        .background(Ink.paper)
        .onChange(of: persona) { _, next in Persona.store(next) }
    }

    private func with(_ change: (inout Persona) -> Void) -> Persona {
        var next = persona
        change(&next)
        return next
    }

    private func part<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            Text(title).font(Ink.readingBold).foregroundStyle(Ink.ink)
            ScrollView(.horizontal) {
                HStack(spacing: Ink.Space.m) { content() }
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func swatch(_ name: String, picked: Bool, preview: Persona, _ pick: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Ink.Motion.unfold) { pick() }
        } label: {
            VStack(spacing: Ink.Space.s) {
                Whale(size: 56, persona: preview, still: true)
                Text(name).font(Ink.footnote).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
            }
            .padding(Ink.Space.s)
            .frame(minWidth: 76)
            .background(picked ? Ink.paperRaised : .clear, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(picked ? Ink.accent.opacity(0.55) : Ink.rule, lineWidth: picked ? 1.5 : 1))
        }
        .buttonStyle(PressStyle())
    }

    private func chip(_ name: String, picked: Bool, _ pick: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Ink.Motion.settle) { pick() }
        } label: {
            Text(name)
                .font(Ink.secondary)
                .foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                .padding(.horizontal, Ink.Space.m)
                .frame(height: 32)
                .background(picked ? Ink.paperRaised : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(picked ? Ink.accent.opacity(0.5) : Ink.rule, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    private func color(_ name: String, _ color: Color) -> some View {
        VStack(spacing: Ink.Space.xs) {
            RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
                .frame(height: 44)
            Text(name).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        }
    }
}

/// One pose's picture: tap to pick from the photo library, hold to clear.
private struct PictureSlot: View {
    let pose: WhalePose
    @Binding var persona: Persona
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(spacing: Ink.Space.xs) {
            PhotosPicker(selection: $item, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                        .fill(Ink.paperRaised)
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous).strokeBorder(Ink.rule, style: StrokeStyle(lineWidth: 1, dash: persona.pictures[pose.rawValue] == nil ? [4, 3] : [])))
                    if let name = persona.pictures[pose.rawValue], let image = Pictures.image(name) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
                    } else {
                        Image(systemName: "plus").foregroundStyle(Ink.inkFaint)
                    }
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(PressStyle())
            .contextMenu {
                if persona.pictures[pose.rawValue] != nil {
                    Button("移除", systemImage: "trash", role: .destructive) { persona.pictures[pose.rawValue] = nil }
                }
            }
            Text(pose.word).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let name = Pictures.keep(data) {
                    withAnimation(Ink.Motion.unfold) {
                        persona.pictures[pose.rawValue] = name
                        persona.kind = .picture
                    }
                    Haptics.tick(0.6)
                }
                item = nil
            }
        }
    }
}
