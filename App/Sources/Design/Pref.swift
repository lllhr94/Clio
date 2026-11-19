import SwiftUI

/// The user's settings for how Clio looks and how conversations behave. Read anywhere; `@AppStorage` with the same keys redraws views.
enum Pref {
    private static var store: UserDefaults { .standard }

    private static func double(_ key: String, _ fallback: Double) -> Double { store.object(forKey: key) == nil ? fallback : store.double(forKey: key) }
    private static func int(_ key: String, _ fallback: Int) -> Int { store.object(forKey: key) == nil ? fallback : store.integer(forKey: key) }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) == nil ? fallback : store.bool(forKey: key) }

    // MARK: 纸墨 — how it looks

    enum Face: String, CaseIterable, Identifiable {
        // 书卷 first: Latin and figures in the system serif, Chinese in PingFang, as the best reading apps set it.
        case serif, sans, rounded, song
        var id: String { rawValue }
        var title: String {
            switch self {
            case .song: "宋体"
            case .sans: "苹方"
            case .rounded: "圆体"
            case .serif: "书卷"
            }
        }
    }

    static var face: Face { Face(rawValue: store.string(forKey: "look.face") ?? "") ?? .serif }
    static var size: Double { double("look.size", 17) }
    static var leading: Double { double("look.leading", 10) }

    /// Once: the new reading type replaces the old default (宋体, tight lines) for anyone who had not changed it.
    static func settleType() {
        guard !store.bool(forKey: "look.typeset2") else { return }
        store.set(true, forKey: "look.typeset2")
        if store.string(forKey: "look.face") == nil || store.string(forKey: "look.face") == "song" { store.set("serif", forKey: "look.face") }
        let size = double("look.size", 17)
        let step = [14.0, 15.5, 17, 19].enumerated().min { abs($0.element - size) < abs($1.element - size) }?.offset ?? 2
        store.set([14.0, 15.5, 17, 19][step], forKey: "look.size")
        store.set([8.0, 9, 10, 11][step], forKey: "look.leading")
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
