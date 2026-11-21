import SwiftUI

struct LookPage: View {
    @AppStorage("look.scheme") private var scheme = "system"

    var body: some View {
        PreferenceForm(L.t("settingsHome.theme"), reset: reset) {
            Section(L.t("settingsHome.theme")) {
                Picker(L.t("settingsHome.lightMode"), selection: $scheme) {
                    Text(L.t("settings.followSystem")).tag("system")
                    Text(L.t("settings.lightAppearance")).tag("light")
                    Text(L.t("settings.darkAppearance")).tag("dark")
                }
                .pickerStyle(.segmented)
                palettes
                Toggle(L.t("settings.oled"), isOn: Binding(get: { Theme.shared.oled }, set: { Theme.shared.setOled($0) }))
            }
        }
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
                        VStack(spacing: Ink.Space.xs) {
                            Circle().fill(palette.accent).frame(width: 28, height: 28)
                                .padding(Ink.Space.xs)
                                .overlay(Circle().strokeBorder(picked ? palette.accent : Color.clear, lineWidth: 2))
                            Text(palette.title).font(.system(size: Ink.Size.small, weight: picked ? .semibold : .regular)).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.format("settingsHome.accentLabel", palette.title))
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private func reset() {
        scheme = "system"
        Theme.shared.pick("dai")
        Theme.shared.setOled(false)
    }
}

struct ReadingSizePage: View {
    @AppStorage("look.size") private var size = 17.0
    @AppStorage("look.leading") private var leading = 0.0

    private static let sizes = [15.0, 16, 17, 19, 21, 24]

    private var sizeStep: Binding<Int> {
        Binding(
            get: { Self.sizes.indices.min { abs(Self.sizes[$0] - size) < abs(Self.sizes[$1] - size) } ?? 2 },
            set: { size = Self.sizes[$0]; Haptics.tick(0.5) }
        )
    }

    private var density: Binding<Int> {
        Binding(
            get: { UIScale.levels.firstIndex { abs($0.factor - UIScale.shared.value) < 0.01 } ?? 2 },
            set: { step in
                Haptics.tick(0.5)
                withAnimation(Ink.Motion.settle) { UIScale.shared.value = UIScale.levels[step].factor }
            }
        )
    }

    var body: some View {
        PreferenceForm(L.t("settingsHome.size"), reset: reset) {
            Section {
                ProseView(text: L.t("settingsHome.readingSample"))
                    .padding(.vertical, Ink.Space.s)
                    .animation(Ink.Motion.settle, value: size)
                Picker(L.t("settingsHome.fontSize"), selection: sizeStep) {
                    ForEach(Self.sizes.indices, id: \.self) { index in
                        Text(L.t("settingsHome.textSize\(index)")).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: L.t("settingsHome.lineSpacing"), value: Binding(
                    get: { min(16, max(4, Pref.leading)) }, set: { leading = $0 }
                ), range: 4...16, step: 0.5) { String(format: "%.1f", $0) }
                if leading > 0 {
                    Button(L.t("settingsHome.automaticSpacing")) { leading = 0 }
                }
            } header: { Text(L.t("settings.chatTextSize")) } footer: { Text(L.t("settingsHome.readingSizeNote")) }

            Section {
                Picker(L.t("settings.uiDensity"), selection: density) {
                    ForEach(UIScale.levels.indices, id: \.self) { index in
                        Text(L.t("settingsHome.density\(index)")).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                RowLabel("textformat.size", title: L.t("settings.densitySampleTitle"), line: L.t("settings.densitySampleLine"), end: .valueChevron(L.t("settings.sample")))
                    .padding(.horizontal, -Ink.Space.l)
                    .allowsHitTesting(false)
            } header: { Text(L.t("settings.uiDensity")) } footer: { Text(L.t("settings.densityNote")) }
        }
    }

    private func reset() {
        size = 17
        leading = 0
        UIScale.shared.value = 1
    }
}

struct ToneSettingsPage: View {
    var body: some View {
        PreferenceForm(L.t("styleSwitcher.title"), reset: reset) {
            Section {
                ToneCards()
                    .listRowInsets(EdgeInsets(top: Ink.Space.m, leading: Ink.Space.m, bottom: Ink.Space.m, trailing: Ink.Space.m))
                if !Theme.shared.plain {
                    Toggle(L.t("styleSwitcher.dailyHintToggle"), isOn: Binding(get: { Theme.shared.hint }, set: { Theme.shared.setHint($0) }))
                }
            } footer: {
                Text(Theme.shared.plain ? L.t("styleSwitcher.subtitle") : L.t("styleSwitcher.dailyHintDesc"))
            }
        }
    }

    private func reset() {
        Theme.shared.setPlain(false)
        Theme.shared.setHint(true)
    }
}

struct ChatDisplayPage: View {
    @AppStorage("look.haptics") private var haptics = true
    @AppStorage("look.fade") private var fade = true
    @AppStorage("look.stats") private var stats = true
    @AppStorage("look.traceOpen") private var traceOpen = false
    @AppStorage("look.thinking") private var showThinking = true
    @AppStorage("pulse.on") private var pulseOn = true
    @AppStorage("chat.faces") private var faces = false

    var body: some View {
        PreferenceForm(L.t("settingsHome.display"), reset: reset) {
            Section {
                Toggle(L.t("settings.chatFaces"), isOn: $faces)
                Toggle(L.t("settings.keepThinking"), isOn: $showThinking)
                Toggle(L.t("settings.expandSteps"), isOn: $traceOpen)
                Toggle(L.t("settings.preReplyThought"), isOn: $pulseOn)
                Toggle(L.t("settings.fadeReply"), isOn: $fade)
                Toggle(L.t("settings.haptics"), isOn: $haptics)
                Toggle(L.t("settings.showReplyStats"), isOn: $stats)
            }
        }
    }

    private func reset() {
        haptics = true
        fade = true
        stats = true
        traceOpen = false
        showThinking = true
        pulseOn = true
        faces = false
    }
}

struct ChatContextPage: View {
    @AppStorage("chat.autoCompress") private var autoCompress = true
    @AppStorage("chat.compressAt") private var compressAt = 60_000
    @AppStorage("chat.keepRecent") private var keepRecent = 12
    @AppStorage("chat.contextChars") private var contextChars = 48_000
    @AppStorage("chat.contextCount") private var contextCount = 0
    @AppStorage("chat.temperature") private var temperature = -1.0
    @AppStorage("chat.maxOutput") private var maxOutput = 0

    var body: some View {
        PreferenceForm(L.t("settingsHome.context"), reset: reset) {
            Section {
                Toggle(L.t("settings.autoCompress"), isOn: $autoCompress)
                if autoCompress {
                    Stepper(L.format("settingsHome.compressAt", compressAt / 1000), value: $compressAt, in: 20_000...300_000, step: 10_000)
                }
                Stepper(L.format("settingsHome.keepRecent", keepRecent), value: $keepRecent, in: 4...40, step: 2)
            } header: { Text(L.t("settings.contextCompaction")) } footer: {
                Text(L.t("settings.autoCompressNote"))
            }

            Section {
                Stepper(L.format("settingsHome.contextChars", contextChars / 1000), value: $contextChars, in: 8_000...400_000, step: 8_000)
                Stepper(contextCount == 0 ? L.t("settingsHome.unlimitedMessages") : L.format("settingsHome.contextCount", contextCount),
                        value: $contextCount, in: 0...200, step: 10)
                Toggle(L.t("settings.customTemperature"), isOn: Binding(get: { temperature >= 0 }, set: { temperature = $0 ? 0.7 : -1 }))
                if temperature >= 0 {
                    LabeledSlider(title: L.t("settingsHome.temperature"), value: $temperature, range: 0...2, step: 0.1) { String(format: "%.1f", $0) }
                }
                Picker(L.t("settingsHome.maxReply"), selection: $maxOutput) {
                    Text(L.t("settings.modelDefault")).tag(0)
                    ForEach([2048, 4096, 8192, 16_384, 32_768], id: \.self) { count in
                        Text(count.formatted()).tag(count)
                    }
                }
            } header: { Text(L.t("settings.modelContext")) } footer: {
                Text(L.t("settings.contextLimitNote"))
            }
        }
    }

    private func reset() {
        autoCompress = true
        compressAt = 60_000
        keepRecent = 12
        contextChars = 48_000
        contextCount = 0
        temperature = -1
        maxOutput = 0
    }
}

struct NotificationSettingsPage: View {
    @AppStorage("notify.done") private var notifyDone = true
    @AppStorage("live.on") private var liveOn = true
    @AppStorage("bg.continue") private var bgContinue = false
    @AppStorage(KeepAwake.key) private var keepAwake = false

    var body: some View {
        PreferenceForm(L.t("settingsHome.notifications"), reset: reset) {
            Section {
                Toggle(L.t("settings.notifyBackground"), isOn: $notifyDone)
                Toggle(L.t("settings.liveProgress"), isOn: $liveOn)
            }
            Section {
                Toggle(L.t("settings.keepAwake"), isOn: $keepAwake)
                Toggle(L.t("settings.backgroundContinue"), isOn: $bgContinue)
            } header: { Text(L.t("settings.background")) } footer: {
                Text(L.t("settings.backgroundProgressNote"))
            }
        }
    }

    private func reset() {
        notifyDone = true
        liveOn = true
        keepAwake = false
        bgContinue = false
    }
}

struct MorningSettingsPage: View {
    @AppStorage("morning.on") private var morningOn = false
    @AppStorage("diary.on") private var diaryOn = false
    @AppStorage("morning.hour") private var morningHour = 7

    var body: some View {
        PreferenceForm(L.t("settingsHome.morning"), reset: reset) {
            Section {
                Toggle(L.t("settings.dailyBrief"), isOn: $morningOn)
                if morningOn {
                    Stepper(L.format("settingsHome.morningHour", morningHour), value: $morningHour, in: 5...11)
                }
            } header: { Text(L.t("agent.morningBrief")) } footer: {
                Text(L.t("settings.dailyBriefNote"))
            }
            Section {
                Toggle(L.t("settings.eveningDiary"), isOn: $diaryOn)
            } header: { Text(L.t("settings.companionRoutine")) } footer: {
                Text(L.t("settings.eveningDiaryNote"))
            }
        }
        .onChange(of: morningOn) { _, _ in TeamModel.scheduleMorning() }
        .onChange(of: morningHour) { _, _ in TeamModel.scheduleMorning() }
    }

    private func reset() {
        morningOn = false
        morningHour = 7
        diaryOn = false
    }
}

struct PrivacySettingsPage<VaultRow: View>: View {
    @AppStorage("lock.faceid") private var faceLock = false
    @ViewBuilder var vaultRow: VaultRow

    var body: some View {
        PreferenceForm(L.t("settings.faceLock"), reset: { faceLock = false }) {
            Section {
                Toggle(L.t("settings.faceLock"), isOn: $faceLock)
            } header: { Text(L.t("settings.appLock")) } footer: {
                Text(L.t("settings.faceLockNote"))
            }
            Section { vaultRow }
        }
    }
}

private struct PreferenceForm<Content: View>: View {
    let title: String
    let reset: () -> Void
    @ViewBuilder var content: Content

    init(_ title: String, reset: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.reset = reset
        self.content = content()
    }

    var body: some View {
        Form {
            PaperRows {
                content
                Section {
                    Button(L.t("actions.resetDefaults"), role: .destructive) {
                        reset()
                        Haptics.thud()
                    }
                }
            }
        }
        .paperForm()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let shown: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.xs) {
            HStack {
                Text(title)
                Spacer()
                Text(shown(value)).foregroundStyle(Ink.inkSoft).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step).accessibilityLabel(title)
        }
    }
}
