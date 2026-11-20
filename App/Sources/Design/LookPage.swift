import SwiftUI
import UIKit

/// 纸墨与絮语: how Clio looks, how it feels in the hand, and how conversations are carried.
struct LookPage: View {
    /// Opened from a search in 设置: this section is scrolled to and lit up for a moment.
    var focus: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var lit: String?

    @AppStorage("look.scheme") private var scheme = "system"
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
    @AppStorage("bg.continue") private var bgContinue = false
    @AppStorage(KeepAwake.key) private var keepAwake = false
    @AppStorage("look.fps") private var fps = false
    @AppStorage("lock.faceid") private var faceLock = false
    @AppStorage("look.thinking") private var showThinking = true
    @AppStorage("pulse.on") private var pulseOn = true

    /// The reading sizes on offer, each with the line spacing that suits it.
    static let sizes: [(title: String, size: Double, leading: Double)] = [
        // Reaching well past the system's own largest reading size: 楷体 and 文楷 read smaller than 苹方 at the same size.
        ("小", 15, 7.5), ("较小", 16, 8), ("中", 17, 8.5), ("大", 19, 9.5), ("特大", 21, 10.5), ("超大", 24, 12),
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
                } header: { Text(L.t("settings.chatTextSize")) } footer: { Text(L.t("settings.chatTextSizeNote")) }
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
                    RowLabel("textformat.size", title: L.t("settings.densitySampleTitle"), line: L.t("settings.densitySampleLine"), end: .valueChevron(L.t("settings.sample")))
                        .padding(.horizontal, -Ink.Space.l)
                        .allowsHitTesting(false)
                } header: { Text(L.t("settings.uiDensity")) } footer: { Text(L.t("settings.densityNote")) }
                .spot("ui", lit)

                Section(L.t("settings.appearance")) {
                    Picker("明暗", selection: $scheme) {
                        Text(L.t("settings.followSystem")).tag("system")
                        Text(L.t("settings.lightAppearance")).tag("light")
                        Text(L.t("settings.darkAppearance")).tag("dark")
                    }
                    .pickerStyle(.segmented)
                    NavigationLink {
                        FontPage()
                    } label: {
                        HStack {
                            Text(L.t("settings.fonts"))
                            Spacer()
                            Text("\(Pref.face.title) · \(Pref.mark.title) · \(Pref.code == .maple ? "Maple" : "等宽")")
                                .font(.system(size: Ink.Size.sub)).foregroundStyle(Ink.inkSoft)
                        }
                    }
                    .spot("font", lit)
                    palettes
                    Toggle(L.t("settings.oled"), isOn: Binding(get: { Theme.shared.oled }, set: { Theme.shared.setOled($0) }))
                }

                Section {
                    ToneCards()
                        .listRowInsets(EdgeInsets(top: Ink.Space.m, leading: Ink.Space.m, bottom: Ink.Space.m, trailing: Ink.Space.m))
                    if !Theme.shared.plain {
                        Toggle(L.t("styleSwitcher.dailyHintToggle"), isOn: Binding(get: { Theme.shared.hint }, set: { Theme.shared.setHint($0) }))
                    }
                } header: { Text(L.t("styleSwitcher.title")) } footer: {
                    Text(Theme.shared.plain ? L.t("styleSwitcher.subtitle") : L.t("styleSwitcher.dailyHintDesc"))
                }
                .spot("tone", lit)

                Section(L.t("settings.motion")) {
                    Toggle(L.t("settings.haptics"), isOn: $haptics)
                    Toggle(L.t("settings.fadeReply"), isOn: $fade)
                    Toggle(L.t("settings.showReplyStats"), isOn: $stats)
                    Toggle(L.t("settings.expandSteps"), isOn: $traceOpen)
                    Toggle(L.t("settings.keepThinking"), isOn: $showThinking)
                    Toggle(L.t("settings.preReplyThought"), isOn: $pulseOn)
                    Toggle(L.t("settings.showFrameRate"), isOn: $fps)
                }
                .spot("motion", lit)

                Section {
                    Toggle(L.t("settings.faceLock"), isOn: $faceLock)
                } header: { Text(L.t("settings.appLock")) } footer: {
                    Text(L.t("settings.faceLockNote"))
                }
                .spot("lock", lit)

                Section {
                    Toggle(L.t("settings.autoCompress"), isOn: $autoCompress)
                    if autoCompress {
                        Stepper("超过 \(compressAt / 1000) 千字时压缩", value: $compressAt, in: 20_000...300_000, step: 10_000)
                    }
                    Stepper("压缩后留最近 \(keepRecent) 条原文", value: $keepRecent, in: 4...40, step: 2)
                } header: { Text(L.t("settings.contextCompaction")) } footer: {
                    Text(L.t("settings.autoCompressNote"))
                }
                .spot("compress", lit)

                Section {
                    Stepper("每次带上最近 \(contextChars / 1000) 千字", value: $contextChars, in: 8_000...400_000, step: 8_000)
                    Stepper(contextCount == 0 ? "条数不限" : "最多带 \(contextCount) 条", value: $contextCount, in: 0...200, step: 10)
                    Toggle(L.t("settings.customTemperature"), isOn: Binding(get: { temperature >= 0 }, set: { temperature = $0 ? 0.7 : -1 }))
                    if temperature >= 0 {
                        LabeledSlider(title: "温度", value: $temperature, range: 0...2, step: 0.1) { String(format: "%.1f", $0) }
                    }
                    Picker("最长回复", selection: $maxOutput) {
                        Text(L.t("settings.modelDefault")).tag(0)
                        Text("2 千").tag(2048)
                        Text("4 千").tag(4096)
                        Text("8 千").tag(8192)
                        Text("1.6 万").tag(16384)
                        Text("3.2 万").tag(32768)
                    }
                } header: { Text(L.t("settings.modelContext")) } footer: {
                    Text(L.t("settings.contextLimitNote"))
                }
                .spot("context", lit)

                Section {
                    Toggle(L.t("settings.dailyBrief"), isOn: $morningOn)
                    if morningOn {
                        Stepper("\(morningHour) 点以后第一次打开时写", value: $morningHour, in: 5...11)
                    }
                } header: { Text(L.t("agent.morningBrief")) } footer: {
                    Text(L.t("settings.dailyBriefNote"))
                }
                .onChange(of: morningOn) { _, _ in TeamModel.scheduleMorning() }
                .spot("morning", lit)

                Section {
                    Toggle(L.t("settings.eveningDiary"), isOn: $diaryOn)
                } header: { Text(L.t("settings.companionRoutine")) } footer: {
                    Text(L.t("settings.eveningDiaryNote"))
                }
                .onChange(of: morningHour) { _, _ in TeamModel.scheduleMorning() }

                Section {
                    Toggle(L.t("settings.notifyBackground"), isOn: $notifyDone)
                    Toggle(L.t("settings.liveProgress"), isOn: $liveOn)
                    Toggle(L.t("settings.keepAwake"), isOn: $keepAwake)
                    Toggle(L.t("settings.backgroundContinue"), isOn: $bgContinue)
                } header: { Text(L.t("settings.background")) } footer: {
                    Text(L.t("settings.backgroundProgressNote"))
                }
                .spot("notify", lit)

                Section {
                    Button(L.t("actions.resetDefaults"), role: .destructive) { reset() }
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
            .navigationTitle(L.t("settings.appearanceAndChat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.t("actions.done")) { dismiss() } } }
        }
        .clioScheme(scheme)
    }

    /// 主色: the accent everything is drawn with.
    private var palettes: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(L.t("settings.accentColor"))
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
        for key in ["look.scheme", "look.face", "look.mark", "look.code", "look.ui", "look.size", "look.leading", "look.haptics", "look.fade", "look.stats", "look.traceOpen", "look.fps", "notify.done", "live.on", "look.accent", "look.plainNames", "look.oled", "look.toneHint", "look.thinking", "pulse.on", "lock.faceid", "bg.continue", "bg.keepAwake",
                    "chat.autoCompress", "chat.compressAt", "chat.keepRecent", "chat.contextChars", "chat.contextCount", "chat.temperature", "chat.maxOutput"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        scheme = "system"; size = 17; leading = 8; haptics = true; fade = true; stats = true; traceOpen = false; fps = false; notifyDone = true
        autoCompress = true; compressAt = 60_000; keepRecent = 12; contextChars = 48_000; contextCount = 0; temperature = -1; maxOutput = 0
        liveOn = true
        UIScale.shared.value = 1.0
        Theme.shared.setFace(.serif)
        Theme.shared.setMark(.wenkai)
        Theme.shared.setCode(.maple)
        Theme.shared.pick("dai")
        Theme.shared.setPlain(false)
        Theme.shared.setOled(false)
        Theme.shared.setHint(true)
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
