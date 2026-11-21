import Observation
import SwiftUI
import UIKit

/// The accent the user picked in 纸墨与絮语. Ink reads it, so every view drawn with the accent redraws when it changes.
@Observable
final class Theme {
    static let shared = Theme()

    private(set) var key: String = UserDefaults.standard.string(forKey: "look.accent") ?? "dai"

    /// Plain names instead of the poetic ones (`Words`).
    private(set) var plain: Bool = UserDefaults.standard.bool(forKey: "look.plainNames")

    /// 日常旁注: in 书卷, the everyday words in small gray beside a name.
    private(set) var hint: Bool = UserDefaults.standard.object(forKey: "look.toneHint") as? Bool ?? true

    func setHint(_ value: Bool) {
        hint = value
        UserDefaults.standard.set(value, forKey: "look.toneHint")
    }

    /// Dark mode on pure black, for OLED screens. Off, dark mode is a warm ink-grey, not black.
    private(set) var oled: Bool = UserDefaults.standard.bool(forKey: "look.oled")

    /// Light mode on pure white instead of paper, as most apps are.
    private(set) var white: Bool = UserDefaults.standard.bool(forKey: "look.white")

    /// The tint of your own bubbles: "" follows the paper, or one of the palette keys (黛 胭 竹 缃 藤 墨).
    private(set) var bubble: String = UserDefaults.standard.string(forKey: "look.bubble") ?? ""

    func setBubble(_ value: String) {
        bubble = value
        UserDefaults.standard.set(value, forKey: "look.bubble")
    }

    func setWhite(_ value: Bool) {
        white = value
        UserDefaults.standard.set(value, forKey: "look.white")
    }

    func setOled(_ value: Bool) {
        oled = value
        UserDefaults.standard.set(value, forKey: "look.oled")
    }

    func setPlain(_ value: Bool) {
        plain = value
        UserDefaults.standard.set(value, forKey: "look.plainNames")
    }

    /// The reading face, and the face of titles and inscriptions (see `Pref.Face`).
    private(set) var face: Pref.Face = Pref.Face(rawValue: UserDefaults.standard.string(forKey: "look.face") ?? "") ?? .serif
    private(set) var mark: Pref.Face = Pref.Face(rawValue: UserDefaults.standard.string(forKey: "look.mark") ?? "") ?? .wenkai

    private(set) var code: Pref.Code = Pref.Code(rawValue: UserDefaults.standard.string(forKey: "look.code") ?? "") ?? .maple

    func setCode(_ value: Pref.Code) {
        code = value
        UserDefaults.standard.set(value.rawValue, forKey: "look.code")
    }

    func setFace(_ value: Pref.Face) {
        face = value
        UserDefaults.standard.set(value.rawValue, forKey: "look.face")
    }

    func setMark(_ value: Pref.Face) {
        mark = value
        UserDefaults.standard.set(value.rawValue, forKey: "look.mark")
    }

    func pick(_ key: String) {
        self.key = key
        UserDefaults.standard.set(key, forKey: "look.accent")
    }

    var palette: Ink.Palette { Ink.palettes.first { $0.key == key } ?? Ink.palettes[0] }

    // Reading size, line height and light / dark: set from several pages with `@AppStorage`, read everywhere through
    // `Pref`. Kept here so every view that read them is drawn again the moment they change — before, only the reply
    // text followed a new size, and other sheets kept the old light or dark until reopened.
    private(set) var size: Double = Theme.number("look.size", 17)
    private(set) var lineHeight: Double = Theme.number("look.lineHeight", Pref.defaultLineHeight)
    private(set) var scheme: String = UserDefaults.standard.string(forKey: "look.scheme") ?? "system"
    @ObservationIgnored private var watching: NSObjectProtocol?
    /// Bumped when 宋体 or 楷体 finishes downloading, so text already drawn in the stand-in face is drawn again in it.
    private(set) var fontsArrived = 0
    func fontArrived() { fontsArrived += 1 }

    init() {
        watching = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    private static func number(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    private func refresh() {
        let size = Self.number("look.size", 17)
        if size != self.size { self.size = size }
        let line = Self.number("look.lineHeight", Pref.defaultLineHeight)
        if line != lineHeight { lineHeight = line }
        let scheme = UserDefaults.standard.string(forKey: "look.scheme") ?? "system"
        if scheme != self.scheme {
            self.scheme = scheme
            applyScheme()
        }
    }

    /// Light or dark for every window at once, so sheets already open (and the lock cover) change too.
    func applyScheme() {
        let style: UIUserInterfaceStyle = scheme == "light" ? .light : (scheme == "dark" ? .dark : .unspecified)
        MainActor.assumeIsolated {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows where window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
            }
        }
    }
}

/// Clio's design system: every color, type size, space and corner comes from here.
enum Ink {
    static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    // MARK: Colors

    /// Paper and its raised sheets take a breath of the accent's hue, so a whole page leans the same way (黛 keeps the plain paper).
    /// The grounds: paper (or pure white) in light mode, warm ink-grey (or pure black) in dark mode.
    static var paper: Color {
        let theme = Theme.shared, palette = theme.palette
        return pair(theme.white ? 0xFFFFFF : palette.paperLight, theme.oled ? 0x000000 : palette.paperDark)
    }
    static var paperRaised: Color {
        let theme = Theme.shared, palette = theme.palette
        return pair(theme.white ? 0xF4F4F5 : palette.raisedLight, theme.oled ? 0x121212 : palette.raisedDark)
    }
    static let ink = pair(0x2B2A27, 0xECE6DA)
    static let inkSoft = pair(0x6F6A60, 0xA39C8E)
    static let inkFaint = pair(0xA8A294, 0x6E685D)
    /// 朱: the seal's cinnabar, and the paper-white of the character cut into it. Only for the seal.
    static let seal = pair(0xB23A2B, 0xC5564A)

    // Exported artwork and image previews keep their own contrast in either appearance.
    enum Artwork {
        static let paper = Color(hex: 0xF7F3EA)
        static let darkPaper = Color(hex: 0x1F1D1A)
        static let blossom = Color(hex: 0xF8ECEA)
        static let paperText = Color(hex: 0x3A4A5A)
        static let darkPaperText = Color(hex: 0xE6DFD1)
        static let blossomText = Color(hex: 0x6A4650)
        static let white = Color(hex: 0xFFFFFF)
        static let black = Color(hex: 0x000000)
        static let badgeRed = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    }

    /// Code in a reply, from the same pigments as everything else; lighter in dark mode so they read on dark paper.
    enum Code {
        static let keyword = pair(0x6F5C96, 0xB3A3D6)
        static let function = pair(0x4A6A8A, 0x8FB0CF)
        static let string = pair(0x4F7A5A, 0x8DBB97)
        static let number = pair(0xA9772F, 0xD9A65C)
        /// A block of what a program printed, not code to read.
        static let output = pair(0x4F7A5A, 0x8DBB97)
    }

    /// A failure in the conversation: the card's ground.
    static let stopWash = pair(0xF4E3E0, 0x3A2624)

    /// The tiles settings rows lead with: one pigment per group, deep enough for a white glyph, the same in light
    /// and dark (as a printed tile would be). Named for the colors Clio's palette already uses.
    enum Tile {
        /// 黛: AI, models.
        static let dai = pair(0x4F7099, 0x5B7DA6)
        /// 胭: companions.
        static let yan = pair(0xA9554C, 0xB86259)
        /// 缃: what they can do.
        static let xiang = pair(0xA9772F, 0xB5843C)
        /// 墨: tools.
        static let mo = pair(0x57534D, 0x6A655E)
        /// 藤: how it looks.
        static let teng = pair(0x6F5C96, 0x7D6AA4)
        /// 竹: general.
        static let zhu = pair(0x4D7C5B, 0x5A8968)
        /// Switched off.
        static let off = pair(0xB4AEA3, 0x4C4842)
        /// The glyph on a tile.
        static let glyph = pair(0xFFFFFF, 0xFFFFFF)
        /// The accent the user picked, kept deep in dark mode too so a white glyph reads on it.
        static var accent: Color { Theme.shared.palette.tile }
    }
    static let sealInk = pair(0xFBF3EA, 0xFBF3EA)
    static var rule: Color {
        let theme = Theme.shared, palette = theme.palette
        return theme.white ? pair(0xE4E4E7, palette.ruleDark) : palette.rule
    }
    /// The accent and its pale ground, from the palette the user picked.
    static var accent: Color { Theme.shared.palette.accent }
    static var accentWash: Color { Theme.shared.palette.wash }

    struct Palette: Identifiable {
        var key: String
        var title: String
        var accent: Color
        /// The accent as a tile ground: the light-mode accent in both modes.
        var tile: Color
        var wash: Color
        var paper: Color
        var raised: Color
        var rule: Color
        var mine: Color
        /// The light-mode paper, for the pure-black dark mode that keeps the light one as it is.
        var paperLight: UInt32
        var raisedLight: UInt32
        var paperDark: UInt32
        var raisedDark: UInt32
        var ruleDark: UInt32
        var mineDark: UInt32
        var id: String { key }

        /// `light` and `dark` are the accent in both modes; `tint` is how much of it the neutrals take (0 for none).
        init(key: String, title: String, light: UInt32, dark: UInt32, wash: Color, tint: Double) {
            self.key = key
            self.title = title
            self.accent = Ink.pair(light, dark)
            self.tile = Ink.pair(light, Ink.mix(light, 0xFFFFFF, 0.08))
            self.wash = wash
            func mixed(_ baseLight: UInt32, _ baseDark: UInt32, _ amount: Double) -> Color {
                Ink.pair(Ink.mix(baseLight, light, amount * tint), Ink.mix(baseDark, dark, amount * tint))
            }
            paper = mixed(0xF6F1E7, 0x1C1A17, 0.05)
            raised = mixed(0xFBF8F1, 0x26231F, 0.035)
            paperLight = Ink.mix(0xF6F1E7, light, 0.05 * tint)
            raisedLight = Ink.mix(0xFBF8F1, light, 0.035 * tint)
            paperDark = Ink.mix(0x1C1A17, dark, 0.05 * tint)
            raisedDark = Ink.mix(0x26231F, dark, 0.035 * tint)
            ruleDark = Ink.mix(0x37332D, dark, 0.08 * tint)
            mineDark = Ink.mix(0x322E28, dark, 0.07 * tint)
            rule = mixed(0xE4DCCB, 0x37332D, 0.08)
            mine = mixed(0xECE4D3, 0x322E28, 0.07)
        }
    }

    /// `amount` of `color` into `base`, channel by channel.
    static func mix(_ base: UInt32, _ color: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((base >> shift) & 0xFF), b = Double((color >> shift) & 0xFF)
            return UInt32((a + (b - a) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// 主色: ink colors with old names. 黛 is the first and the default.
    static let palettes: [Palette] = [
        Palette(key: "dai", title: "黛", light: 0x4A6A8A, dark: 0x8FB0CF, wash: pair(0xE3EAF0, 0x2A3642), tint: 0),
        Palette(key: "yan", title: "胭", light: 0xA4504A, dark: 0xD98C84, wash: pair(0xF2E1DE, 0x3D2B29), tint: 1),
        Palette(key: "zhu", title: "竹", light: 0x4F7A5A, dark: 0x8DBB97, wash: pair(0xE1ECE3, 0x283A2D), tint: 1),
        Palette(key: "xiang", title: "缃", light: 0x93702F, dark: 0xD2AA62, wash: pair(0xF3E8D2, 0x3D3322), tint: 0.6),
        Palette(key: "teng", title: "藤", light: 0x6E5A92, dark: 0xA996CF, wash: pair(0xE9E4F2, 0x332C42), tint: 1),
        Palette(key: "mo", title: "墨", light: 0x3F3D39, dark: 0xC9C2B5, wash: pair(0xE8E5DF, 0x35332F), tint: 0.5),
    ]
    /// Your own bubbles: the paper's tint, or a soft wash of the colour you picked (text stays plain ink, so it
    /// always reads).
    static var bubble: Color {
        let theme = Theme.shared
        guard !theme.bubble.isEmpty, let picked = palettes.first(where: { $0.key == theme.bubble }) else { return mine }
        return picked.wash
    }
    static var mine: Color {
        let theme = Theme.shared, palette = theme.palette
        return theme.white ? pair(0xEFEFF1, palette.mineDark) : palette.mine
    }
    static let ok = pair(0x5E8C6A, 0x7FB08C)
    static let warn = pair(0xC08A3E, 0xD9A65C)
    static let stop = pair(0xB4534B, 0xD4776F)

    /// The grounds a companion's portrait can sit on, each with a name to keep and a name to show.
    static let tints: [(key: String, title: String, color: Color)] = [
        ("dai", "黛", pair(0xE3EAF0, 0x2A3642)),
        ("yan", "胭", pair(0xEFE3E0, 0x3A2E2C)),
        ("zhu", "竹", pair(0xE3EADF, 0x2C352B)),
        ("xiang", "缃", pair(0xF1E6D2, 0x3A3226)),
        ("teng", "藤", pair(0xE8E3EF, 0x332E3A)),
        ("cang", "苍", pair(0xE6E6E3, 0x2F2F2D)),
    ]

    static var washes: [Color] { tints.map(\.color) }

    /// A companion's own ground: its chosen tint, or one picked from its name so it stays the same.
    static func wash(named name: String?) -> Color {
        let key = name ?? ""
        if let tint = tints.first(where: { $0.key == key }) { return tint.color }
        let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return tints[sum % tints.count].color
    }

    static func wash(for bot: BotInfo) -> Color { wash(named: bot.color ?? bot.id) }

    // MARK: Type

    /// Whether a font is on this phone now (Apple's 宋体 and 楷体 only once fetched).
    /// Asked for every line of text drawn, so the answer is kept: looking a font up each time made long replies stutter.
    /// `FontShelf` clears it when a download ends.
    static func has(_ name: String) -> Bool {
        if let known = fonts.object(forKey: name as NSString) { return known.boolValue }
        let found = UIFont(name: name, size: 12) != nil
        fonts.setObject(NSNumber(value: found), forKey: name as NSString)
        return found
    }

    /// Forget which fonts are on the phone (one has just been fetched).
    static func recheckFonts() { fonts.removeAllObjects() }

    private static let fonts = NSCache<NSString, NSNumber>()

    /// Any face at any size; a face not on the phone yet stands in as the system serif.
    static func face(_ face: Pref.Face, _ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        if face.downloads { _ = Theme.shared.fontsArrived }
        if let name = face.postScript(bold: bold), has(name) {
            return .custom(name, size: size, relativeTo: style)
        }
        switch face {
        case .sans: return .system(size: size, weight: bold ? .semibold : .regular)
        case .rounded: return .system(size: size, weight: bold ? .semibold : .regular, design: .rounded)
        default: return .system(size: size, weight: bold ? .semibold : .regular, design: .serif)
        }
    }

    /// The reading face for titles, a companion's words, notes: the system serif for Latin and figures,
    /// PingFang for Chinese; 宋体, 楷体 or 文楷 when the user reads in one of them.
    static func serif(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        switch Pref.face {
        case .song, .kai, .wenkai: face(Pref.face, size, bold: bold, relativeTo: style)
        default: .system(size: size, weight: bold ? .semibold : .regular, design: .serif)
        }
    }

    /// Code, commands, paths, the terminal, model names: Maple Mono unless 系统等宽 is picked in 字体.
    /// Chinese inside falls back to the system's own.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular, preference: Pref.Code? = nil) -> Font {
        if (preference ?? Pref.code) == .maple {
            let light = weight == .regular || weight == .light || weight == .thin || weight == .ultraLight
            if let font = mapleWithChinese(size, bold: !light) { return Font(font) }
        }
        return Font.system(size: size, weight: weight).monospaced()
    }

    /// The same, for UIKit views (the terminal).
    static func uiMono(_ size: CGFloat, bold: Bool = false) -> UIFont {
        if Pref.code == .maple, let font = mapleWithChinese(size, bold: bold) { return font }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Maple Mono, with Clio Mono CN behind it for Chinese: every Chinese character exactly two letters wide, so
    /// columns of output and code line up even with Chinese in them (Maple Mono CN, cut to GB2312).
    private static func mapleWithChinese(_ size: CGFloat, bold: Bool) -> UIFont? {
        let name = bold ? "MapleMono-SemiBold" : "MapleMono-Regular"
        guard has(name), let latin = UIFont(name: name, size: size) else { return nil }
        guard has("ClioMonoCN-Regular") else { return latin }
        let chinese = UIFontDescriptor(fontAttributes: [.name: "ClioMonoCN-Regular"])
        return UIFont(descriptor: latin.fontDescriptor.addingAttributes([.cascadeList: [chinese]]), size: size)
    }

    /// Titles and inscriptions, in the face picked for them in 字体 (文楷 unless changed): the welcome pages,
    /// what a companion hands you, the line over an empty page. Never the running text or buttons.
    static func mark(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        face(Pref.mark, size, bold: bold, relativeTo: style)
    }

    /// The word 「Clio」 at the head of the sidebar: Hoefler Text italic, which every iPhone has.
    static func wordmark(_ size: CGFloat) -> Font { .custom("HoeflerText-Italic", size: size, relativeTo: .title) }

    static var display: Font { serif((30 * UIScale.factor).rounded(), bold: true, relativeTo: .largeTitle) }
    static var title: Font { serif((22 * UIScale.factor).rounded(), bold: true, relativeTo: .title2) }
    /// Reading text, in the face and size the user picked in 纸墨.
    static var reading: Font { body(Pref.size, bold: false) }
    static var readingBold: Font { body(Pref.size, bold: true) }

    static func body(_ size: Double, bold: Bool) -> Font { face(Pref.face, CGFloat(size), bold: bold) }
    /// The five sizes everything outside the reading text is set in (Apple's caption 2, footnote, subheadline, body, title 3).
    enum Size {
        static var micro: CGFloat { (11 * UIScale.factor).rounded() }
        static var small: CGFloat { (13 * UIScale.factor).rounded() }
        static var sub: CGFloat { (15 * UIScale.factor).rounded() }
        static var body: CGFloat { (17 * UIScale.factor).rounded() }
        static var title: CGFloat { (20 * UIScale.factor).rounded() }
    }
    static var label: Font { .system(size: Ink.Size.body, weight: .medium) }
    static var secondary: Font { .system(size: Ink.Size.sub) }
    static var footnote: Font { .system(size: Ink.Size.small) }
    /// Code, three points under the reading size, so it sits with the text around it at every size.
    static var code: Font { mono(max(12, Pref.size - 3)) }

    /// The space between the lines of reading text.
    static var leading: CGFloat { Pref.leading }
    /// Between paragraphs: about 12 points at the usual size, as Open Minis sets it.
    static var paragraphGap: CGFloat { CGFloat(Pref.size) * 0.72 }

    // MARK: Space and corners

    enum Space {
        static var xs: CGFloat { 4 * UIScale.factor }
        static var s: CGFloat { 8 * UIScale.factor }
        static var m: CGFloat { 12 * UIScale.factor }
        static var l: CGFloat { 16 * UIScale.factor }
        static var xl: CGFloat { 24 * UIScale.factor }
        static var xxl: CGFloat { 32 * UIScale.factor }
        static var huge: CGFloat { 48 * UIScale.factor }
        /// The page's side margin.
        static var page: CGFloat { 20 * UIScale.factor }
    }

    /// Floating controls over a page (the top bar, the composer, chips): one height, one distance from the edges,
    /// so what sits side by side lines up and both sides mirror each other.
    enum Bar {
        static var height: CGFloat { 44 * UIScale.factor }
        static var edge: CGFloat { 12 * UIScale.factor }
    }

    /// Corners follow the iPhone's own: continuous curves, large on cards (like grouped lists in iOS 26),
    /// smaller inside them so inner corners sit concentric with the outer ones.
    enum Radius {
        /// Three corners, nothing else: cards and anything that holds things, things inside a card
        /// (pictures, code, a step's details), and capsules for every control (buttons, chips, fields on one line).
        /// Icons are squircles with their own fixed proportion (`Kit.iconCorner`).
        static var small: CGFloat { 14 * UIScale.factor }
        static var field: CGFloat { 28 * UIScale.factor }
        static var card: CGFloat { 28 * UIScale.factor }
        static var sheet: CGFloat { 34 * UIScale.factor }
    }

    // MARK: Motion

    enum Motion {
        static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
        static let unfold = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let settle = Animation.smooth(duration: 0.35)
    }
}

/// Anything tappable: gives a little under the finger, springs back, and ticks.
struct PressStyle: ButtonStyle {
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The whole frame takes the tap, not just the drawn strokes and glyphs.
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Ink.Motion.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed, haptic { Haptics.tick(0.5) }
            }
    }
}

extension View {
    /// A card that reads as paper: a raised sheet with a hairline edge.
    func paperCard(radius: CGFloat = Ink.Radius.card) -> some View {
        background(Ink.paperRaised, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Ink.rule.opacity(0.7), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
    }

    /// A small glass capsule: only for controls that float above content.
    func glassChip() -> some View {
        padding(.horizontal, Ink.Space.m)
            .frame(height: Ink.Bar.height)
            .glassFace(in: Capsule())
    }

    /// Liquid Glass for a control with nothing tappable inside (an icon button, a chip).
    /// The system draws the glass itself and takes any touch that lands on it, so taps on the glass around an icon
    /// never reached the button. A nearly clear layer over the glass catches them for SwiftUI.
    func glassFace<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
            .overlay { shape.fill(Color.white.opacity(0.001)) }
            .contentShape(shape)
    }

    /// Your message bubble: a touch of glass, without the cost of real glass on every bubble in a long chat.
    /// The paper tint, a light catching the top edge, a hairline and a soft shadow under it.
    func glassBubble<S: InsettableShape>(in shape: S, tint: Color) -> some View {
        background {
            shape.fill(tint)
                .overlay {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Ink.rule],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        }
    }

    /// Liquid Glass behind a bar that holds its own controls (the composer, an address bar). The clear layer sits
    /// between the glass and the controls: taps between them land on it instead of on the glass.
    func glassBacking<S: Shape>(in shape: S) -> some View {
        background { shape.fill(Color.white.opacity(0.001)) }
            .glassEffect(.regular, in: shape)
    }
}

/// A plain button whose whole frame takes the tap (not only its glyphs), dimming while pressed.
/// `grow` widens the tap area past the frame, for tiny icons such as a close mark.
struct TapStyle: ButtonStyle {
    var grow: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle().inset(by: -grow))
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// Lets a text out glyph by glyph, each one fading in.
struct FadeIn: TextRenderer {
    /// How many glyphs are on their way out; the last `ramp` of them are still fading.
    var shown: Double
    var ramp: Double = 10

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                for slice in run {
                    let alpha = min(1, max(0, (shown - index) / ramp))
                    if alpha > 0 {
                        var soft = context
                        soft.opacity = alpha
                        soft.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// The same color, darker (`amount` below 1) or mixed toward white (`lift` above 0).
    static func shade(_ hex: UInt32, amount: Double = 1, lift: Double = 0) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255 * amount
            return min(1, value + (1 - value) * lift)
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}
