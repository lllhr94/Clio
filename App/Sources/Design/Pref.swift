import SwiftUI

/// The user's settings for how Clio looks and how conversations behave. Read anywhere; `@AppStorage` with the same keys redraws views.
enum Pref {
    private static var store: UserDefaults { .standard }

    private static func double(_ key: String, _ fallback: Double) -> Double { store.object(forKey: key) == nil ? fallback : store.double(forKey: key) }
    private static func int(_ key: String, _ fallback: Int) -> Int { store.object(forKey: key) == nil ? fallback : store.integer(forKey: key) }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) == nil ? fallback : store.bool(forKey: key) }

    // MARK: 纸墨 — how it looks

    /// A face to read or title in. 宋体 and 楷体 are Apple's, fetched the first time they are picked (`FontShelf`);
    /// 文楷 (Clio Kai, from 霞鹜文楷) comes with the app; the rest are the system's own.
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
            case .wenkai: "霞鹜文楷，带手写感，已内置（简体常用字全收）"
            }
        }

        /// The font's own name, regular or bold; nil for the system's faces.
        func postScript(bold: Bool) -> String? {
            switch self {
            case .song: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
            case .kai: bold ? "STKaiti-SC-Bold" : "STKaiti-SC-Regular"
            case .wenkai: bold ? "ClioKai-Medium" : "ClioKai-Regular"
            default: nil
            }
        }

        /// Apple's, fetched on first use.
        var downloads: Bool { self == .song || self == .kai }

        /// What titles and inscriptions can be set in.
        static let marks: [Face] = [.wenkai, .kai, .song, .serif, .sans]
    }

    static var face: Face { Theme.shared.face }
    /// Titles and inscriptions: the welcome pages, what a companion hands you, the line over an empty page.
    static var mark: Face { Theme.shared.mark }
    static var size: Double { double("look.size", 17) }
    /// The space added between lines: a fixed share of the size, so every size reads about 1.6 lines apart.
    static var leading: Double { size * 0.5 }

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
    static var scheme: String { store.string(forKey: "look.scheme") ?? "system" }
    static var haptics: Bool { bool("look.haptics", true) }
    static var fade: Bool { bool("look.fade", true) }
    static var stats: Bool { bool("look.stats", true) }
    static var traceOpen: Bool { bool("look.traceOpen", false) }

    // MARK: 絮语 — how conversations behave

    /// How much of the conversation goes to the model, in characters.
    static var contextChars: Int { int("chat.contextChars", 48_000) }
    /// At most this many recent messages; 0 for no limit.
    static var contextCount: Int { int("chat.contextCount", 0) }
    /// Below 0: the model's own default.
    static var temperature: Double { double("chat.temperature", -1) }
    /// 0: the model's own default.
    static var maxOutput: Int { int("chat.maxOutput", 0) }
    static var autoCompress: Bool { bool("chat.autoCompress", true) }
    /// Compress once the conversation passes this many characters.
    static var compressAt: Int { int("chat.compressAt", 60_000) }
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
