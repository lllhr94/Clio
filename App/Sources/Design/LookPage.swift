import SwiftUI
import UIKit

/// 纸墨与絮语: how Clio looks, how it feels in the hand, and how conversations are carried.
struct LookPage: View {
    /// Opened from a search in 设置: this section is scrolled to and lit up for a moment.
    var focus: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var lit: String?

    @AppStorage("look.scheme") private var scheme = "system"
    @AppStorage("look.face") private var face = "serif"
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.leading") private var leading = 11.0
    @AppStorage("look.haptics") private var haptics = true
    @AppStorage("look.fade") private var fade = true
    @AppStorage("look.stats") private var stats = true
    @AppStorage("look.traceOpen") private var traceOpen = false
    @AppStorage("mascot.shown") private var mascot = true

    @AppStorage("chat.autoCompress") private var autoCompress = true
    @AppStorage("chat.compressAt") private var compressAt = 60_000
    @AppStorage("chat.keepRecent") private var keepRecent = 12
    @AppStorage("chat.contextChars") private var contextChars = 48_000
    @AppStorage("chat.contextCount") private var contextCount = 0
    @AppStorage("chat.temperature") private var temperature = -1.0
    @AppStorage("chat.maxOutput") private var maxOutput = 0
    @AppStorage("morning.on") private var morningOn = false
    @AppStorage("diary.on") private var diaryOn = false
    @AppStorage("morning.hour") private var morningHour = 7
    @AppStorage("notify.done") private var notifyDone = true
    @AppStorage("live.on") private var liveOn = true
    @AppStorage("bg.continue") private var bgContinue = true
    @AppStorage("look.fps") private var fps = false
    @AppStorage("lock.faceid") private var faceLock = false
    @AppStorage("look.thinking") private var showThinking = true
    @AppStorage("pulse.on") private var pulseOn = true

    /// The reading sizes on offer, each with the line spacing that suits it.
    static let sizes: [(title: String, size: Double, leading: Double)] = [
        ("超小", 15, 7.5), ("小", 16, 8), ("中", 17, 8.5), ("大", 19, 9.5),
    ]

    /// The step closest to a size kept from before (when it was a slider).
    static func sizeStep(_ size: Double) -> Int {
        sizes.indices.min { abs(sizes[$0].size - size) < abs(sizes[$1].size - size) } ?? 2
    }

    private let sample = """
    ## 小样
    窗外落了一阵**细雨**，案头的茶还温着。这里是正文的模样，换字号和字体时会跟着变。

    - 列表也随之更换
    - 行内的 `代码` 保持等宽
    """

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
            Form {
                PaperRows {
                Section {
                    ProseView(text: sample)
                        .padding(.vertical, Ink.Space.s)
                        .listRowBackground(Ink.paperRaised)
                        .animation(Ink.Motion.settle, value: size)
                    // Four sizes, each with its own line spacing, so every one reads well; the sample above changes at once.
                    Picker("字号", selection: Binding(get: { Self.sizeStep(size) }, set: { step in
                        Haptics.tick(0.5)
                        size = Self.sizes[step].size
                        leading = Self.sizes[step].leading
                    })) {
                        ForEach(Self.sizes.indices, id: \.self) { step in Text(Self.sizes[step].title).tag(step) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("对话字号") } footer: { Text("对话里正文的大小，上面的小样跟着变。") }
                .spot("size", lit)

                Section {
                    // The whole interface, not only the words: spacing, icons, rows and corners grow or shrink together.
                    Picker("界面大小", selection: Binding(get: { UIScale.levels.firstIndex { abs($0.factor - UIScale.shared.value) < 0.01 } ?? 2 }, set: { step in
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { UIScale.shared.value = UIScale.levels[step].factor }
                    })) {
                        ForEach(UIScale.levels.indices, id: \.self) { step in Text(UIScale.levels[step].title).tag(step) }
                    }
                    .pickerStyle(.segmented)
                    RowLabel("textformat.size", title: "设置里的一行", line: "换一档看看，整个界面一起变", end: .valueChevron("示例"))
                        .padding(.horizontal, -Ink.Space.l)
                        .allowsHitTesting(false)
                } header: { Text("界面大小") } footer: { Text("按钮、图标、列表和间距一起放大缩小，对话字号另外调。") }
                .spot("ui", lit)

                Section(Words.t("纸墨")) {
                    Picker("明暗", selection: $scheme) {
                        Text("跟随系统").tag("system")
                        Text("纸白").tag("light")
                        Text("夜墨").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Picker("正文字体", selection: $face) {
                        ForEach(Pref.Face.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    palettes
                    Toggle("深色时用纯黑", isOn: Binding(get: { Theme.shared.oled }, set: { Theme.shared.setOled($0) }))
                    Picker(Words.t("叫法"), selection: Binding(get: { Theme.shared.plain }, set: { value in
                        Haptics.tick(0.5)
                        Theme.shared.setPlain(value)
                    })) {
                        Text("诗意").tag(false)
                        Text("普通").tag(true)
                    }
                }

                Section("动静") {
                    Toggle("触感反馈", isOn: $haptics)
                    Toggle("回复逐字淡入", isOn: $fade)
                    Toggle("回复下显示耗时和用量", isOn: $stats)
                    Toggle(Words.t("行迹默认展开"), isOn: $traceOpen)
                    Toggle("回复上留着思考过程", isOn: $showThinking)
                    Toggle("开口前先写一段心绪", isOn: $pulseOn)
                    Toggle("聊天页的形象", isOn: $mascot)
                    Toggle("角落显示帧率", isOn: $fps)
                }
                .spot("motion", lit)

                Section {
                    Toggle("用面容锁住 Clio", isOn: $faceLock)
                } header: { Text("上锁") } footer: {
                    Text("切到后台再回来时要先过面容（或密码）。手机没设密码时不会锁。")
                }
                .spot("lock", lit)

                Section {
                    Toggle("聊久了自动压缩前文", isOn: $autoCompress)
                    if autoCompress {
                        Stepper("超过 \(compressAt / 1000) 千字时压缩", value: $compressAt, in: 20_000...300_000, step: 10_000)
                    }
                    Stepper("压缩后留最近 \(keepRecent) 条原文", value: $keepRecent, in: 4...40, step: 2)
                } header: { Text("压缩") } footer: {
                    Text(Words.t("较早的话写成提要，原文留在絮语页"))
                }
                .spot("compress", lit)

                Section {
                    Stepper("每次带上最近 \(contextChars / 1000) 千字", value: $contextChars, in: 8_000...400_000, step: 8_000)
                    Stepper(contextCount == 0 ? "条数不限" : "最多带 \(contextCount) 条", value: $contextCount, in: 0...200, step: 10)
                    Toggle("自己定温度", isOn: Binding(get: { temperature >= 0 }, set: { temperature = $0 ? 0.7 : -1 }))
                    if temperature >= 0 {
                        LabeledSlider(title: "温度", value: $temperature, range: 0...2, step: 0.1) { String(format: "%.1f", $0) }
                    }
                    Picker("最长回复", selection: $maxOutput) {
                        Text("模型默认").tag(0)
                        Text("2 千").tag(2048)
                        Text("4 千").tag(4096)
                        Text("8 千").tag(8192)
                        Text("1.6 万").tag(16384)
                        Text("3.2 万").tag(32768)
                    }
                } header: { Text("交给模型的") } footer: {
                    Text("带得多记得多，也更慢更费")
                }
                .spot("context", lit)

                Section {
                    Toggle(Words.t("每天一封晨信"), isOn: $morningOn)
                    if morningOn {
                        Stepper("\(morningHour) 点以后第一次打开时写", value: $morningHour, in: 5...11)
                    }
                } header: { Text(Words.t("晨信")) } footer: {
                    Text("看看日程、提醒和天气，写一封便笺")
                }
                .onChange(of: morningOn) { _, _ in TeamModel.scheduleMorning() }
                .spot("morning", lit)

                Section {
                    Toggle("晚上写日记", isOn: $diaryOn)
                } header: { Text(Words.t("旅伴的日常")) } footer: {
                    Text(Words.t("晚上离开时，旅伴各写一页日记"))
                }
                .onChange(of: morningHour) { _, _ in TeamModel.scheduleMorning() }

                Section {
                    Toggle("离开时干完活、出错都通知我", isOn: $notifyDone)
                    Toggle(Words.t("锁屏和灵动岛显示旅伴在做什么"), isOn: $liveOn)
                    Toggle(Words.t("切走后让旅伴接着做一会儿"), isOn: $bgContinue)
                } header: { Text("在后台") } footer: {
                    Text("干活时在锁屏和灵动岛显示进度。切走后系统会给一张进度卡，可以在那里叫停；系统忙时可能不给。")
                }
                .spot("notify", lit)

                Section {
                    Button("全部恢复默认", role: .destructive) { reset() }
                }
            }
            }
            .paperForm()
            .task {
                guard let focus else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(Ink.Motion.unfold) { reader.scrollTo(focus, anchor: .top) }
                withAnimation(.easeOut(duration: 0.25)) { lit = focus }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeOut(duration: 0.6)) { lit = nil }
            }
            }
            .navigationTitle(Words.t("纸墨与絮语"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好了") { dismiss() } } }
        }
        .clioScheme(scheme)
    }

    /// 主色: the accent everything is drawn with.
    private var palettes: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text("主色")
            HStack(spacing: 0) {
                ForEach(Ink.palettes) { palette in
                    let picked = Theme.shared.key == palette.key
                    Button {
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { Theme.shared.pick(palette.key) }
                    } label: {
                        VStack(spacing: 4) {
                            Circle().fill(palette.accent).frame(width: 28, height: 28)
                                .padding(3)
                                .overlay(Circle().strokeBorder(picked ? palette.accent : Color.clear, lineWidth: 2))
                            Text(palette.title).font(.system(size: Ink.Size.small, weight: picked ? .semibold : .regular)).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("主色：\(palette.title)")
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private func reset() {
        for key in ["look.scheme", "look.face", "look.ui", "look.size", "look.leading", "look.haptics", "look.fade", "look.stats", "look.traceOpen", "look.fps", "notify.done", "live.on", "look.accent", "look.plainNames", "look.oled", "look.thinking", "pulse.on", "lock.faceid", "bg.continue",
                    "chat.autoCompress", "chat.compressAt", "chat.keepRecent", "chat.contextChars", "chat.contextCount", "chat.temperature", "chat.maxOutput"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        scheme = "system"; face = "song"; size = 17; leading = 8; haptics = true; fade = true; stats = true; traceOpen = false; fps = false; notifyDone = true
        autoCompress = true; compressAt = 60_000; keepRecent = 12; contextChars = 48_000; contextCount = 0; temperature = -1; maxOutput = 0
        liveOn = true
        UIScale.shared.value = 1.0
        Theme.shared.pick("dai")
        Theme.shared.setPlain(false)
        Theme.shared.setOled(false)
        Haptics.thud()
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let shown: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(shown(value)).foregroundStyle(Ink.inkSoft).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}


extension View {
    /// A section 设置 can point at: its id for scrolling, and lit up while `lit` names it.
    func spot(_ id: String, _ lit: String?) -> some View {
        self.id(id).listRowBackground(lit == id ? Ink.accentWash : Ink.paperRaised)
    }
}
