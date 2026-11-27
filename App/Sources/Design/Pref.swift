import SwiftUI

/// The user's settings for how Clio looks and how conversations behave. Read anywhere; `@AppStorage` with the same keys redraws views.
enum Pref {
    private static var store: UserDefaults { .standard }

    private static func double(_ key: String, _ fallback: Double) -> Double { store.object(forKey: key) == nil ? fallback : store.double(forKey: key) }
    private static func int(_ key: String, _ fallback: Int) -> Int { store.object(forKey: key) == nil ? fallback : store.integer(forKey: key) }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) == nil ? fallback : store.bool(forKey: key) }

    // MARK: 纸墨 — how it looks

    /// A face to read or title in. 宋体 and 楷体 are Apple's, fetched the first time they are picked (`FontShelf`);
    /// 文楷 (Clio Kai, from 霞鹜文楷 GB) comes with the app; the rest are the system's own.
    enum Face: String, CaseIterable, Identifiable {
        // 书卷 first: Latin and figures in the system serif, Chinese in PingFang, as the best reading apps set it.
        case serif, sans, rounded, song, kai, wenkai
        var id: String { rawValue }
        var title: String {
            switch self {
            case .song: "宋体"
            case .sans: "苹方"
            case .rounded: "圆体"
            case .serif: "书卷"
            case .kai: "楷体"
            case .wenkai: "文楷"
            }
        }

        var note: String {
            switch self {
            case .serif: "系统衬线，中文是苹方，英文数字最好看"
            case .sans: "系统黑体，最清楚"
            case .rounded: "圆头，柔和"
            case .song: "苹果提供的宋体，第一次用要下载"
            case .kai: "苹果提供的楷体，第一次用要下载"
            case .wenkai: "霞鹜文楷屏幕阅读版的粗细，带手写感，已内置"
            }
        }

        /// The font's own name, regular or bold; nil for the system's faces.
        func postScript(bold: Bool) -> String? {
            switch self {
            case .song: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
            case .kai: bold ? "STKaiti-SC-Bold" : "STKaiti-SC-Regular"
            // The screen-reading cut, as LXGW WenKai Screen does it: the Medium weight for reading, since Regular reads
            // thin on a phone. Bold words are the same face with a thin outline (see `ProseText` inline).
            case .wenkai: "ClioKai-Medium"
            default: nil
            }
        }

        /// Apple's, fetched on first use.
        var downloads: Bool { self == .song || self == .kai }

        /// What titles and inscriptions can be set in.
        static let marks: [Face] = [.wenkai, .kai, .song, .serif, .sans]
    }

    /// What code, commands, the terminal and model names are set in.
    enum Code: String, CaseIterable, Identifiable {
        case maple, system
        var id: String { rawValue }
        var title: String { self == .maple ? "Maple Mono" : "系统等宽" }
        var note: String { self == .maple ? "圆头，柔和，已内置" : "SF Mono，苹果自带" }
    }

    /// Quick starter bundles for typography; orthogonal to color palette/theme.
    enum ReadingPreset: String, CaseIterable, Identifiable {
        case standard, editorial, compact, comfortable
        var id: String { rawValue }

        var face: Face {
            switch self {
            case .standard: .sans
            case .editorial: .serif
            case .compact: .sans
            case .comfortable: .wenkai
            }
        }

        var size: Double {
            switch self {
            case .standard: 17
            case .editorial: 17
            case .compact: 15
            case .comfortable: 19
            }
        }

        var lineHeight: Double {
            switch self {
            case .standard: 1.65
            case .editorial: 1.65
            case .compact: 1.50
            case .comfortable: 1.80
            }
        }

        var paragraphGap: Double {
            switch self {
            case .standard: 13
            case .editorial: 13
            case .compact: 10
            case .comfortable: 16
            }
        }

        func matches(face: Face, size: Double, lineHeight: Double, paragraphGap: Double) -> Bool {
            self.face == face
                && abs(self.size - size) < 0.05
                && abs(self.lineHeight - lineHeight) < 0.01
                && abs(self.paragraphGap - paragraphGap) < 0.1
        }
    }

    static var face: Face { Theme.shared.face }
    static var code: Code { Theme.shared.code }
    /// Titles and inscriptions: the welcome pages, what a companion hands you, the line over an empty page.
    static var mark: Face { Theme.shared.mark }
    static var size: Double { Theme.shared.size }
    /// How tall a line is, as a multiple of the reading size: 紧凑 1.35 · 适中 1.5 · 舒展 1.65 · 宽松 1.8.
    static let lineHeights: [Double] = [1.35, 1.5, 1.65, 1.8]
    static let defaultLineHeight = 1.65
    static var lineHeight: Double { Theme.shared.lineHeight }

    /// Single-source SwiftUI `.lineSpacing(...)` computed from `SafeLineBox`.
    static var leading: Double {
        Double(SafeLineBox.resolve(userSize: CGFloat(size), contentMultiplier: CGFloat(lineHeight), face: face).swiftUILineSpacing)
    }

    /// Once: the new reading type replaces the old default (宋体, tight lines) for anyone who had not changed it.
    static func settleType() {
        guard !store.bool(forKey: "look.typeset4") else { return }
        store.set(true, forKey: "look.typeset4")
        // The face is moved off 宋体 only once; someone who picked 宋体 again afterwards keeps it.
        if !store.bool(forKey: "look.typeset2"), store.string(forKey: "look.face") == nil || store.string(forKey: "look.face") == "song" {
            store.set("serif", forKey: "look.face")
        }
        store.set(true, forKey: "look.typeset2")
        let size = double("look.size", 17)
        let step = [14.0, 15.5, 17, 19].enumerated().min { abs($0.element - size) < abs($1.element - size) }?.offset ?? 2
        store.set([15.0, 16, 17, 19][step], forKey: "look.size")
    }
    /// "system", "light" or "dark".
    static var scheme: String { Theme.shared.scheme }

    /// When haptics play: always, muted automatically in Low Power Mode (`auto`), or off.
    enum HapticMode: String, CaseIterable, Identifiable {
        case always, auto, off
        var id: String { rawValue }
    }

    static var hapticMode: HapticMode {
        if let raw = store.string(forKey: "look.hapticMode"), let mode = HapticMode(rawValue: raw) {
            return mode
        }
        return bool("look.haptics", true) ? .auto : .off
    }

    static var haptics: Bool { hapticMode != .off }

    /// Haptic strength calibrated across Wave 1–5; returns `.off` when `hapticMode` is `.off`.
    enum HapticIntensity: String, CaseIterable, Identifiable {
        case off, gentle, standard, crisp
        var id: String { rawValue }
        static let activeCases: [HapticIntensity] = [.gentle, .standard, .crisp]

        var scale: CGFloat {
            switch self {
            case .off: 0.0
            case .gentle: 0.62
            case .standard: 1.0
            case .crisp: 1.25
            }
        }
    }
    static var hapticIntensity: HapticIntensity {
        guard hapticMode != .off else { return .off }
        return HapticIntensity(rawValue: store.string(forKey: "look.hapticIntensity") ?? "") ?? .standard
    }

    /// Heading weight preference introduced for Wave 2 editorial typography.
    enum HeadingWeight: String, CaseIterable, Identifiable {
        case medium, semibold, bold
        var id: String { rawValue }

        nonisolated var uiWeight: UIFont.Weight {
            switch self {
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        nonisolated var swiftUIWeight: Font.Weight {
            switch self {
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }
    static var headingWeight: HeadingWeight { Theme.shared.headingWeight }

    /// Reading list density preference reserved for Wave 3 layout tuning.
    enum UIDensity: String, CaseIterable, Identifiable {
        case comfortable, standard, compact
        var id: String { rawValue }
    }
    static var uiDensity: UIDensity { Theme.shared.uiDensity }

    static let paragraphGapStops: [Double] = [10, 13, 16, 20]
    static let defaultParagraphGap = 13.0
    static var paragraphGap: Double { Theme.shared.paragraphGap }

    static let readingWidthStops: [Double] = [560, 640, 700]
    static let defaultReadingWidth = 640.0
    static var readingWidth: Double { Theme.shared.readingWidth }

    /// Streaming reveal pace: gentle (舒缓), balanced (均衡, default), or fast (极速).
    enum RevealPace: String, CaseIterable, Identifiable, Sendable {
        case gentle, balanced, fast
        var id: String { rawValue }
    }
    static let revealPaceKey = "look.revealPace"
    static var revealPace: RevealPace { Theme.shared.revealPace }

    static var clreqSqueeze: Bool { Theme.shared.clreqSqueeze }
    static var reduceVisualEffects: Bool { Theme.shared.reduceVisualEffects }
    static var fade: Bool { bool("look.fade", true) }
    static var stats: Bool { bool("look.stats", true) }
    static var traceOpen: Bool { bool("look.traceOpen", false) }
    static var useUIKitChatList: Bool { bool("look.uikitChatList", true) }

    // MARK: 絮语 — how conversations behave

    /// How much of the conversation goes to the model: this share of the model's own window (0.2 to 0.9).
    static var contextShare: Double { min(max(double("chat.contextShare", 0.8), 0.1), 0.9) }
    /// At most this many recent messages; 0 for no limit.
    static var contextCount: Int { int("chat.contextCount", 0) }
    /// Below 0: the model's own default.
    static var temperature: Double { double("chat.temperature", -1) }
    /// 0: the model's own default.
    static var maxOutput: Int { int("chat.maxOutput", 0) }
    /// Tool-calling steps allowed in one turn before pausing; 40 covers most debugging and multi-file runs.
    static let defaultMaxSteps = 40
    static let maxStepStops = [16, 24, 40, 64, 100]
    static var maxSteps: Int { min(max(int("chat.maxSteps", defaultMaxSteps), 8), 100) }
    static var autoCompress: Bool { bool("chat.autoCompress", true) }
    /// Compress once the conversation passes this share of the model's window (always below `contextShare`).
    static var compressShare: Double { min(max(double("chat.compressShare", 0.6), 0.1), 0.9) }
    /// How many recent messages stay word for word after compressing.
    static var keepRecent: Int { int("chat.keepRecent", 12) }

    // MARK: 晨信

    static var morningOn: Bool { bool("morning.on", false) }
    /// In the evening, the companions talked with that day each write a page of diary (costs a little: one short request each).
    static var diaryOn: Bool { bool("diary.on", false) }
    /// A notification when a companion finishes, fails, or stops halfway, while the app is away.
    static var notifyDone: Bool { bool("notify.done", true) }
    /// Under a reply, a folded line with what the model thought on the way.
    static var showThinking: Bool { bool("look.thinking", true) }
    /// Scroll-driven collapsing of chat header and composer while browsing history (default off).
    static var immersiveChrome: Bool { bool("look.immersiveChrome", false) }
    /// The frame-rate meter in the corner, for checking smoothness.
    static var fpsMeter: Bool { bool("look.fps", false) }
    static var morningHour: Int { int("morning.hour", 7) }
}

extension View {
    /// Light, dark, or as the system says.
    func clioScheme(_ scheme: String) -> some View {
        preferredColorScheme(scheme == "light" ? .light : (scheme == "dark" ? .dark : nil))
    }
}

extension View {
    /// A Form dressed in paper: raised paper rows, ruled lines, serif titles — the same look as the rest of Clio.
    func paperForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Ink.paper)
            .tint(Ink.accent)
            .environment(\.defaultMinListRowHeight, 48)
    }
}

/// Rows inside a paper Form get the raised paper ground and quiet rules.
struct PaperRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Group { content }
            .listRowBackground(Ink.paperRaised)
            .listRowSeparatorTint(Ink.rule)
    }
}
