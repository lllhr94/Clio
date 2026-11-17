import PhotosUI
import SwiftUI

/// Stage 0: three screens of made-up content, to settle the look before anything real is built on it.
struct ProtoRoot: View {
    enum Page: String, CaseIterable {
        case chat = "絮语"
        case home = "案头"
        case note = "笺"
        case whale = "形象"
    }

    @State private var page: Page = .home
    @Namespace private var marker

    var body: some View {
        ZStack(alignment: .bottom) {
            Ink.paper.ignoresSafeArea()
            Group {
                switch page {
                case .chat: ProtoChat(back: { go(.home) })
                case .home: ProtoHome(open: { go(.chat) })
                case .note: ProtoNote()
                case .whale: ProtoWhale()
                }
            }
            .transition(.blurReplace)
            .padding(.bottom, page == .chat ? 0 : 64)
            if page != .chat { bar }
        }
        .tint(Ink.accent)
    }

    private func go(_ next: Page) {
        withAnimation(Ink.Motion.settle) { page = next }
    }

    private var bar: some View {
        HStack(spacing: Ink.Space.xs) {
            ForEach(Page.allCases, id: \.self) { item in
                Button { go(item) } label: {
                    Text(item.rawValue)
                        .font(Ink.label)
                        .foregroundStyle(page == item ? Ink.ink : Ink.inkSoft)
                        .padding(.horizontal, Ink.Space.l)
                        .frame(height: 38)
                        .background {
                            if page == item {
                                Capsule().fill(Ink.paperRaised).matchedGeometryEffect(id: "page", in: marker)
                            }
                        }
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(Ink.Space.xs)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, Ink.Space.s)
    }
}

/// 案头: the home screen.
struct ProtoHome: View {
    var open: () -> Void

    private struct Thread: Identifiable {
        let id: Int
        let title: String
        let preview: String
        let when: String
        let wash: Int
    }

    private let threads = [
        Thread(id: 0, title: "周末去哪儿走走", preview: "磁器口周六多云转小雨，记得带伞。", when: "方才", wash: 0),
        Thread(id: 1, title: "十月的花销", preview: "一共花了 6,842，房租占了近一半。", when: "昨日", wash: 3),
        Thread(id: 2, title: "给外婆的信", preview: "第二段我改得口语了些，你看看。", when: "周一", wash: 1),
        Thread(id: 3, title: "注安案例第三章", preview: "这一章常考的三个点我列出来了。", when: "上周", wash: 2),
    ]

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "晨安"
        case 11..<13: "午安"
        case 13..<18: "午后好"
        case 18..<23: "晚上好"
        default: "夜深了"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        Text(greeting)
                            .font(Ink.display)
                            .foregroundStyle(Ink.ink)
                        Text("今天想聊点什么？")
                            .font(Ink.reading)
                            .foregroundStyle(Ink.inkSoft)
                    }
                    Spacer()
                    Whale(size: 96, pose: .idle)
                }
                .padding(.top, Ink.Space.xxl)

                ScrollView(.horizontal) {
                    HStack(spacing: Ink.Space.s) {
                        companion("团子", wash: 0, picked: true)
                        companion("小探", wash: 2, picked: false)
                        companion("墨墨", wash: 1, picked: false)
                        companion("饭团", wash: 3, picked: false)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .padding(.top, Ink.Space.xl)

                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "envelope")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Ink.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("来信").font(Ink.footnote).foregroundStyle(Ink.inkSoft)
                        Text("团子约好 18:30 提醒你泡黄豆").font(Ink.secondary).foregroundStyle(Ink.ink)
                    }
                    Spacer()
                }
                .padding(Ink.Space.l)
                .paperCard()
                .padding(.top, Ink.Space.xl)

                Text("近来的絮语")
                    .font(Ink.title)
                    .foregroundStyle(Ink.ink)
                    .padding(.top, Ink.Space.xxl)
                    .padding(.bottom, Ink.Space.s)

                ForEach(threads) { thread in
                    Button(action: open) {
                        HStack(alignment: .top, spacing: Ink.Space.m) {
                            Whale(size: 28, wash: Ink.washes[thread.wash], still: true)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(thread.title).font(Ink.readingBold).foregroundStyle(Ink.ink)
                                    Spacer()
                                    Text(thread.when).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                                }
                                Text(thread.preview)
                                    .font(Ink.secondary)
                                    .foregroundStyle(Ink.inkSoft)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, Ink.Space.m)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    if thread.id != threads.count - 1 {
                        Rectangle().fill(Ink.rule).frame(height: 1).padding(.leading, 40)
                    }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.huge)
        }
        .scrollIndicators(.hidden)
    }

    private func companion(_ name: String, wash: Int, picked: Bool) -> some View {
        Button(action: open) {
            HStack(spacing: Ink.Space.s) {
                Whale(size: 28, wash: Ink.washes[wash], still: true)
                Text(name).font(Ink.label).foregroundStyle(Ink.ink)
            }
            .padding(.leading, Ink.Space.xs + 2)
            .padding(.trailing, Ink.Space.l)
            .frame(height: 40)
            .background(picked ? Ink.paperRaised : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(picked ? Ink.accent.opacity(0.5) : Ink.rule, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }
}

/// 笺: a reply set as a page to keep or share.
struct ProtoNote: View {
    private enum Theme: String, CaseIterable {
        case paper = "纸"
        case ink = "墨"
        case blossom = "樱"

        var ground: Color {
            switch self {
            case .paper: Color(hex: 0xF7F3EA)
            case .ink: Color(hex: 0x1F1D1A)
            case .blossom: Color(hex: 0xF8ECEA)
            }
        }

        var words: Color {
            switch self {
            case .paper: Color(hex: 0x3A4A5A)
            case .ink: Color(hex: 0xE6DFD1)
            case .blossom: Color(hex: 0x6A4650)
            }
        }

        var line: Color { words.opacity(0.18) }
    }

    @State private var theme: Theme = .paper

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Space.xl) {
                sheet
                    .clipShape(.rect(cornerRadius: Ink.Radius.card))
                    .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
                    .padding(.top, Ink.Space.xl)

                HStack(spacing: Ink.Space.s) {
                    ForEach(Theme.allCases, id: \.self) { item in
                        Button {
                            withAnimation(Ink.Motion.settle) { theme = item }
                        } label: {
                            HStack(spacing: Ink.Space.s) {
                                Circle()
                                    .fill(item.ground)
                                    .overlay(Circle().strokeBorder(Ink.rule, lineWidth: 1))
                                    .frame(width: 18, height: 18)
                                Text(item.rawValue).font(Ink.label).foregroundStyle(Ink.ink)
                            }
                            .padding(.horizontal, Ink.Space.l)
                            .frame(height: 40)
                            .background(theme == item ? Ink.paperRaised : .clear, in: .capsule)
                            .overlay(Capsule().strokeBorder(theme == item ? Ink.accent.opacity(0.5) : Ink.rule, lineWidth: 1))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
            .padding(.horizontal, Ink.Space.page)
            .padding(.bottom, Ink.Space.huge)
        }
        .scrollIndicators(.hidden)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("潮声")
                .font(Ink.serif(40, bold: true, relativeTo: .largeTitle))
                .foregroundStyle(theme.words)
                .padding(.top, Ink.Space.huge)
            Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, Ink.Space.xl)
            VStack(alignment: .leading, spacing: Ink.Space.l + 2) {
                Text("潮水从不赶路。它只是按时来，按时走，像一个守信的老朋友。")
                Text("你站在岸上听，以为它在说话。其实它只是把远处的事，一遍一遍搬到你脚边：某条船刚刚经过，某阵风昨夜来过，某片云在很远的地方化成了雨。")
                Text("听久了，人会慢下来。不是因为没有要紧的事，是因为忽然明白，要紧的事也会像潮水一样，退了还会再来。")
            }
            .font(Ink.serif(18, relativeTo: .body))
            .lineSpacing(10)
            .foregroundStyle(theme.words)
            HStack(spacing: Ink.Space.s) {
                Spacer()
                Whale(size: 22, wash: theme.words.opacity(0.14), tone: theme.words.opacity(0.7), still: true)
                Text("Clio")
                    .font(Ink.serif(14, relativeTo: .footnote))
                    .foregroundStyle(theme.words.opacity(0.6))
                Spacer()
            }
            .padding(.top, Ink.Space.huge)
            .padding(.bottom, Ink.Space.xxl)
        }
        .padding(.horizontal, Ink.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.ground)
    }
}

/// 形象: put a portrait together from swappable parts.
struct ProtoWhale: View {
    @State private var persona = Persona.stored
    @State private var pose: WhalePose = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Space.xl) {
                Text("形象")
                    .font(Ink.display)
                    .foregroundStyle(Ink.ink)
                    .padding(.top, Ink.Space.xxl)
                Text("每一样都能换。以后每位旅伴可以有自己的一套。")
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

                HStack(spacing: Ink.Space.s) {
                    chip("鲸鱼", picked: persona.kind == .whale) { persona.kind = .whale }
                    chip("画像", picked: persona.kind == .picture) { persona.kind = .picture }
                }

                if persona.kind == .picture {
                    VStack(alignment: .leading, spacing: Ink.Space.m) {
                        Text("每个姿态放一张图").font(Ink.readingBold).foregroundStyle(Ink.ink)
                        Text("只放闲坐一张也行，其他姿态会用它加上动作。透明底的图最好看。")
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

                if persona.kind == .whale {
                part("轮廓") {
                    ForEach(0..<WhaleLook.looks.count, id: \.self) { index in
                        swatch(WhaleLook.names[index], picked: persona.outline == index, preview: with { $0.outline = index }) { persona.outline = index }
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
            .background(picked ? Ink.paperRaised : .clear, in: .rect(cornerRadius: Ink.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card).strokeBorder(picked ? Ink.accent.opacity(0.55) : Ink.rule, lineWidth: picked ? 1.5 : 1))
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
            RoundedRectangle(cornerRadius: Ink.Radius.small)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small).strokeBorder(Ink.rule, lineWidth: 1))
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
                    RoundedRectangle(cornerRadius: Ink.Radius.card)
                        .fill(Ink.paperRaised)
                        .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card).strokeBorder(Ink.rule, style: StrokeStyle(lineWidth: 1, dash: persona.pictures[pose.rawValue] == nil ? [4, 3] : [])))
                    if let name = persona.pictures[pose.rawValue], let image = Pictures.image(name) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .clipShape(.rect(cornerRadius: Ink.Radius.card))
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
