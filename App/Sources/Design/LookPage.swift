import Craft
import SwiftUI

struct LookPage: View {
    @AppStorage("look.scheme") private var scheme = "system"

    var body: some View {
        PreferenceForm(L.t("settingsHome.theme"), reset: reset) {
            // No section title: the page is already called 设色, and three of the same word in a row read as a stutter.
            Section {
                Picker(L.t("settingsHome.lightMode"), selection: $scheme) {
                    Text(L.t("settings.followSystem")).tag("system")
                    Text(L.t("settings.lightAppearance")).tag("light")
                    Text(L.t("settings.darkAppearance")).tag("dark")
                }
                .pickerStyle(.segmented)
                palettes
                grounds
                bubbles
            }
        }
    }

    /// The page itself: paper or pure white by day, warm ink-grey or pure black by night.
    private var grounds: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            groundRow(L.t("settings.lightGround"), [(L.t("settings.groundPaper"), 0xF6F1E7, false), (L.t("settings.groundWhite"), 0xFFFFFF, true)],
                      picked: Theme.shared.white) { Theme.shared.setWhite($0) }
            groundRow(L.t("settings.darkGround"), [(L.t("settings.groundInk"), 0x1C1A17, false), (L.t("settings.groundBlack"), 0x000000, true)],
                      picked: Theme.shared.oled) { Theme.shared.setOled($0) }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private func groundRow(_ title: String, _ options: [(String, UInt32, Bool)], picked: Bool, set: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(title)
            HStack(spacing: Ink.Space.m) {
                ForEach(options, id: \.0) { option in
                    let chosen = option.2 == picked
                    Button {
                        Haptics.tick(0.5)
                        withAnimation(Ink.Motion.settle) { set(option.2) }
                    } label: {
                        HStack(spacing: Ink.Space.s) {
                            RoundedRectangle(cornerRadius: Ink.Radius.small / 2, style: .continuous)
                                .fill(Ink.pair(option.1, option.1))
                                .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small / 2, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
                                .frame(width: 26, height: 26)
                            Text(option.0).font(.system(size: Ink.Size.sub, weight: chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? Ink.ink : Ink.inkSoft)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Ink.Space.m)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .background(chosen ? Ink.accentWash : Color.clear, in: .capsule)
                        .overlay(Capsule().strokeBorder(chosen ? Ink.accent.opacity(0.6) : Ink.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }

    /// 我的气泡: the tint of your own messages.
    private var bubbles: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Text(L.t("settings.bubbleColor"))
            HStack(spacing: 0) {
                bubbleChoice("", title: L.t("settings.bubbleAuto"), color: Ink.mine)
                ForEach(Ink.palettes) { palette in bubbleChoice(palette.key, title: palette.title, color: palette.wash) }
            }
        }
        .padding(.vertical, Ink.Space.xs)
    }

    private func bubbleChoice(_ key: String, title: String, color: Color) -> some View {
        let picked = Theme.shared.bubble == key
        return Button {
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) { Theme.shared.setBubble(key) }
        } label: {
            VStack(spacing: Ink.Space.xs) {
                Capsule().fill(color)
                    .overlay(Capsule().strokeBorder(picked ? Ink.accent : Ink.rule, lineWidth: picked ? 2 : 1))
                    .frame(width: 34, height: 22)
                Text(title).font(.system(size: Ink.Size.small, weight: picked ? .semibold : .regular)).foregroundStyle(picked ? Ink.ink : Ink.inkSoft)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
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
        Theme.shared.resetLook()
        scheme = "system"
    }
}

struct ReadingSizePage: View {
    @State private var pendingDensity: Double?
    @State private var draggingDensity = false

    private static let sizes = [15.0, 16, 17, 19, 21, 24]

    private var sizeBinding: Binding<Double> {
        Stops.snapped(
            Binding(get: { Theme.shared.size }, set: { Theme.shared.setSize($0) }),
            to: Self.sizes
        )
    }

    private var lineHeightBinding: Binding<Double> {
        Stops.snapped(
            Binding(get: { Theme.shared.lineHeight }, set: { Theme.shared.setLineHeight($0) }),
            to: Pref.lineHeights
        )
    }

    private var density: Binding<Double> {
        Binding(
            get: { pendingDensity ?? Stops.nearest(UIScale.shared.value, in: UIScale.levels.map(\.factor)) },
            set: { factor in
                if draggingDensity {
                    pendingDensity = factor
                } else {
                    pendingDensity = nil
                    UIScale.shared.value = factor
                }
            }
        )
    }

    var body: some View {
        let theme = Theme.shared
        PreferenceForm(L.t("settingsHome.size"), reset: reset) {
            Section {
                ReadingSamplePreview(
                    rawText: L.t("settingsHome.readingSample"),
                    size: theme.size,
                    lineHeight: theme.lineHeight,
                    face: theme.face,
                    code: theme.code
                )
                StopRow(title: L.t("settingsHome.fontSize"), value: sizeBinding, stops: Self.sizes.indices.map {
                    Stop(value: Self.sizes[$0], name: L.t("settingsHome.textSize\($0)"), detail: "\(Int(Self.sizes[$0])) 点")
                }, opensForShot: Shots.name == "stops")
                StopRow(title: L.t("settingsHome.lineSpacing"), value: lineHeightBinding, stops: Pref.lineHeights.indices.map {
                    Stop(value: Pref.lineHeights[$0], name: L.t("settingsHome.lineHeight\($0)"), detail: String(format: "%g 倍", Pref.lineHeights[$0]))
                })
            } header: { Text(L.t("settings.chatTextSize")) } footer: { Text(L.t("settingsHome.readingSizeNote")) }

            Section {
                StopRow(
                    title: L.t("settings.uiDensity"),
                    value: density,
                    stops: UIScale.levels.indices.map {
                        Stop(value: UIScale.levels[$0].factor, name: L.t("settingsHome.density\($0)"), detail: "\(Int((UIScale.levels[$0].factor * 100).rounded()))%")
                    },
                    onEditingChanged: { editing in
                        draggingDensity = editing
                        if !editing, let committed = pendingDensity {
                            pendingDensity = nil
                            UIScale.shared.value = committed
                        }
                    }
                )
                RowLabel("textformat.size", title: L.t("settings.densitySampleTitle"), line: L.t("settings.densitySampleLine"), end: .valueChevron(L.t("settings.sample")))
                    .padding(.horizontal, -Ink.Space.l)
                    .allowsHitTesting(false)
            } header: { Text(L.t("settings.uiDensity")) } footer: { Text(L.t("settings.densityNote")) }
        }
    }

    private func reset() {
        pendingDensity = nil
        draggingDensity = false
        Theme.shared.setSize(17)
        Theme.shared.setLineHeight(Pref.defaultLineHeight)
        if UIScale.shared.value != 1 { UIScale.shared.value = 1 }
    }
}

/// Lightweight in-place text preview for reading size/line-height stops (avoids rebuilding Markdown AST on drag).
private struct ReadingSamplePreview: View {
    let rawText: String
    let size: Double
    let lineHeight: Double
    let face: Pref.Face
    let code: Pref.Code

    private struct SampleKey: Hashable {
        let rawText: String
        let size: Double
        let face: Pref.Face
        let code: Pref.Code
        let fontsArrived: Int
    }

    @MainActor private static var cache: [SampleKey: AttributedString] = [:]

    var body: some View {
        let fontsArrived = Theme.shared.fontsArrived
        let attributed = Self.attributedSample(rawText: rawText, size: size, face: face, code: code, fontsArrived: fontsArrived)
        Text(attributed)
            .font(Ink.face(face, size, bold: false))
            .foregroundStyle(Ink.ink)
            .lineSpacing(Ink.leading(size: size, lineHeight: lineHeight, face: face))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Ink.Space.s)
    }

    @MainActor
    private static func attributedSample(rawText: String, size: Double, face: Pref.Face, code: Pref.Code, fontsArrived: Int) -> AttributedString {
        let key = SampleKey(rawText: rawText, size: size, face: face, code: code, fontsArrived: fontsArrived)
        if let hit = cache[key] { return hit }
        let built = buildSample(rawText, size: size, face: face, code: code)
        if cache.count >= 24 { cache.removeAll(keepingCapacity: true) }
        cache[key] = built
        return built
    }

    private static func buildSample(_ rawText: String, size: Double, face: Pref.Face, code: Pref.Code) -> AttributedString {
        var result = AttributedString()
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false)
        let headingFont = Ink.face(face, size + 2, bold: true)
        let boldFont = Ink.face(face, size, bold: true)
        let codeFont = Ink.mono(max(12, size - 3), preference: code)

        for (index, rawLine) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var line = String(rawLine)
            var isHeading = false
            if line.hasPrefix("## ") {
                isHeading = true
                line = String(line.dropFirst(3))
            } else if line.hasPrefix("- ") {
                line = "• " + String(line.dropFirst(2))
            }
            var segment = parseInline(line, isHeading: isHeading, headingFont: headingFont, boldFont: boldFont, codeFont: codeFont)
            if isHeading {
                segment.font = headingFont
            }
            result.append(segment)
        }
        return result
    }

    private static func parseInline(
        _ line: String,
        isHeading: Bool,
        headingFont: Font,
        boldFont: Font,
        codeFont: Font
    ) -> AttributedString {
        var out = AttributedString()
        var cursor = line.startIndex
        while cursor < line.endIndex {
            let boldRange = line[cursor...].range(of: "**")
            let codeRange = line[cursor...].range(of: "`")
            let nextMarker: (isBold: Bool, range: Range<String.Index>)?
            if let b = boldRange, let c = codeRange {
                nextMarker = b.lowerBound < c.lowerBound ? (true, b) : (false, c)
            } else if let b = boldRange {
                nextMarker = (true, b)
            } else if let c = codeRange {
                nextMarker = (false, c)
            } else {
                nextMarker = nil
            }
            guard let marker = nextMarker else {
                out.append(AttributedString(String(line[cursor...])))
                break
            }
            if cursor < marker.range.lowerBound {
                out.append(AttributedString(String(line[cursor..<marker.range.lowerBound])))
            }
            let delimiter = marker.isBold ? "**" : "`"
            let searchStart = marker.range.upperBound
            if let closeRange = line[searchStart...].range(of: delimiter) {
                var span = AttributedString(String(line[searchStart..<closeRange.lowerBound]))
                if marker.isBold {
                    span.font = isHeading ? headingFont : boldFont
                } else {
                    span.font = codeFont
                    span.backgroundColor = Ink.mine
                }
                out.append(span)
                cursor = closeRange.upperBound
            } else {
                out.append(AttributedString(String(line[marker.range.lowerBound...])))
                break
            }
        }
        return out
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
    @AppStorage("chat.confirmStop") private var confirmStop = true
    @AppStorage("look.uikitChatList") private var useUIKitChatList = true
    @AppStorage(VoiceTranscription.modeKey) private var voiceModeRaw = VoiceTranscription.Mode.system.rawValue
    @AppStorage(VoiceTranscription.modelKey) private var voiceModel = ""

    private var voiceSummary: String {
        let mode = VoiceTranscription.Mode(rawValue: voiceModeRaw) ?? .system
        if mode == .cloud {
            let trimmed = voiceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L.t("voiceSettings.cloudShort") : trimmed
        }
        return mode.title
    }

    var body: some View {
        PreferenceForm(L.t("settingsHome.display"), reset: reset) {
            Section {
                Toggle(L.t("settings.chatFaces"), isOn: $faces)
                Toggle(L.t("settings.confirmStop"), isOn: $confirmStop)
                Toggle(L.t("settings.keepThinking"), isOn: $showThinking)
                Toggle(L.t("settings.expandSteps"), isOn: $traceOpen)
                Toggle(L.t("settings.preReplyThought"), isOn: $pulseOn)
                Toggle(L.t("settings.fadeReply"), isOn: $fade)
                Toggle(L.t("settings.haptics"), isOn: $haptics)
                Toggle(L.t("settings.showReplyStats"), isOn: $stats)
            }
            Section {
                Toggle(L.t("lookChatList.toggle"), isOn: $useUIKitChatList)
            } footer: {
                Text(L.t("lookChatList.note"))
            }
            Section {
                NavigationLink {
                    VoiceSettingsPage()
                } label: {
                    HStack {
                        Text(L.t("voiceSettings.title"))
                            .foregroundStyle(Ink.ink)
                        Spacer(minLength: Ink.Space.s)
                        Text(voiceSummary)
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.inkSoft)
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(L.t("voiceSettings.rowFooter"))
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
        confirmStop = true
        useUIKitChatList = true
    }
}

struct ChatContextPage: View {
    @AppStorage("chat.autoCompress") private var autoCompress = true
    @AppStorage("chat.contextShare") private var contextShare = 0.8
    @AppStorage("chat.compressShare") private var compressShare = 0.6
    @AppStorage("chat.keepRecent") private var keepRecent = 12
    @AppStorage("chat.contextCount") private var contextCount = 0
    @AppStorage("chat.temperature") private var temperature = -1.0
    @AppStorage("chat.maxOutput") private var maxOutput = 0
    @AppStorage("chat.maxSteps") private var maxSteps = Pref.defaultMaxSteps

    private static let shares = [0.2, 0.4, 0.6, 0.7, 0.8, 0.9]
    private static let compressShares = [0.5, 0.6, 0.7, 0.8]
    private static let keeps = [6, 12, 24, 48]
    private static let counts = [20, 50, 100, 200, 0]
    private static let outputs = [4_096, 8_192, 16_384, 32_768, 65_536, 0]
    private static let temperatures = [-1.0, 0.2, 0.7, 1.0, 1.3]

    /// The default model's window: what each share comes to is said in tokens of that model.
    private var window: Int { TeamModel.shared.defaultWindow }

    var body: some View {
        let window = self.window
        PreferenceForm(L.t("settingsHome.context"), reset: reset) {
            Section {
                StopRow(title: L.t("settingsHome.contextShare"), value: Stops.snapped($contextShare, to: Self.shares),
                        stops: Self.shares.map { Stop(value: $0, name: Self.times($0), detail: L.format("settingsHome.aboutTokens", Tokens.short(Int(Double(window) * $0)))) },
                        line: L.format("settingsHome.modelWindow", Tokens.short(window)))
                StopRow(title: L.t("settingsHome.countLimit"), value: Stops.snapped($contextCount, to: Self.counts),
                        stops: Self.counts.map { Stop(value: $0, name: $0 == 0 ? L.t("settingsHome.unlimitedMessages") : L.format("settingsHome.messages", $0)) })
            } header: { Text(L.t("settings.modelContext")) } footer: {
                Text(L.t("settings.contextLimitNote"))
            }

            Section {
                Toggle(L.t("settings.autoCompress"), isOn: $autoCompress)
                if autoCompress {
                    StopRow(title: L.t("settingsHome.compressShare"), value: compressBinding,
                            stops: Self.compressShares.map { Stop(value: $0, name: Self.times($0), detail: L.format("settingsHome.aboutTokens", Tokens.short(Int(Double(window) * $0)))) },
                            line: compressShare >= contextShare ? L.t("settingsHome.compressBelowNote") : nil)
                    StopRow(title: L.t("settingsHome.keepRecentTitle"), value: Stops.snapped($keepRecent, to: Self.keeps),
                            stops: Self.keeps.map { Stop(value: $0, name: L.format("settingsHome.messages", $0)) })
                }
            } header: { Text(L.t("settings.contextCompaction")) } footer: {
                Text(L.t("settings.autoCompressNote"))
            }

            Section {
                StopRow(title: L.t("settingsHome.temperature"), value: Stops.snapped($temperature, to: Self.temperatures),
                        stops: Self.temperatures.indices.map { Stop(value: Self.temperatures[$0], name: L.t("settingsHome.temperature\($0)"),
                                                                    detail: Self.temperatures[$0] < 0 ? nil : String(format: "%.1f", Self.temperatures[$0])) })
                StopRow(title: L.t("settingsHome.maxReply"), value: Stops.snapped($maxOutput, to: Self.outputs),
                        stops: Self.outputs.map { Stop(value: $0, name: $0 == 0 ? L.t("settings.modelDefault") : Tokens.short($0) + " token") })
                StopRow(title: L.t("settingsHome.maxSteps"), value: Stops.snapped($maxSteps, to: Pref.maxStepStops),
                        stops: Pref.maxStepStops.map { Stop(value: $0, name: L.format("settingsHome.stepsCount", $0)) })
            } header: { Text(L.t("settingsHome.replyGroup")) } footer: {
                Text(L.t("settingsHome.maxStepsNote"))
            }
        }
    }

    /// The compression line always sits below how much goes with a request; past it, older lines would drop
    /// before being summarised. A line set at or above it shows as one stop lower.
    private var compressBinding: Binding<Double> {
        Binding(
            get: {
                let below = Self.compressShares.filter { $0 < contextShare }
                return Stops.nearest(compressShare, in: below.isEmpty ? [Self.compressShares[0]] : below)
            },
            set: { compressShare = $0 }
        )
    }

    private static func times(_ share: Double) -> String { String(format: "%.1f 倍", share) }

    private func reset() {
        autoCompress = true
        contextShare = 0.8
        compressShare = 0.6
        keepRecent = 12
        contextCount = 0
        temperature = -1
        maxOutput = 0
        maxSteps = Pref.defaultMaxSteps
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
                    StopRow(title: L.t("settingsHome.morningTime"), value: Stops.snapped($morningHour, to: Array(5...11)),
                            stops: (5...11).map { Stop(value: $0, name: L.format("settingsHome.hourShort", $0)) },
                            line: L.format("settingsHome.morningHour", morningHour))
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
    @State private var verifying = false
    @ViewBuilder var vaultRow: VaultRow

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { faceLock },
            set: { next in
                if next {
                    faceLock = true
                } else {
                    requestDisableLock()
                }
            }
        )
    }

    private func requestDisableLock() {
        guard faceLock, !verifying else { return }
        verifying = true
        Task { @MainActor in
            let ok = await AppLock.verifyDeviceOwner(reason: "关闭 Clio 面容锁")
            verifying = false
            if ok {
                faceLock = false
            } else {
                Haptics.lock()
            }
        }
    }

    var body: some View {
        PreferenceForm(L.t("settings.faceLock"), reset: {
            if faceLock {
                requestDisableLock()
            }
        }) {
            Section {
                Toggle(L.t("settings.faceLock"), isOn: lockBinding)
                    .disabled(verifying)
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

