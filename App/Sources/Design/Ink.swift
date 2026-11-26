import CoreText
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
        if hint != value { hint = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.toneHint") }
    }

    /// Dark mode on pure black, for OLED screens. Off, dark mode is a warm ink-grey, not black.
    private(set) var oled: Bool = UserDefaults.standard.bool(forKey: "look.oled")

    /// Light mode on pure white instead of paper, as most apps are.
    private(set) var white: Bool = UserDefaults.standard.bool(forKey: "look.white")

    /// The tint of your own bubbles: "" follows the paper, or one of the palette keys (黛 胭 竹 缃 藤 墨).
    private(set) var bubble: String = UserDefaults.standard.string(forKey: "look.bubble") ?? ""

    func setBubble(_ value: String) {
        if bubble != value { bubble = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.bubble") }
    }

    func setWhite(_ value: Bool) {
        if white != value { white = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.white") }
    }

    func setOled(_ value: Bool) {
        if oled != value { oled = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.oled") }
    }

    func setPlain(_ value: Bool) {
        if plain != value { plain = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.plainNames") }
    }

    /// The reading face, and the face of titles and inscriptions (see `Pref.Face`).
    private(set) var face: Pref.Face = Pref.Face(rawValue: UserDefaults.standard.string(forKey: "look.face") ?? "") ?? .serif
    private(set) var mark: Pref.Face = Pref.Face(rawValue: UserDefaults.standard.string(forKey: "look.mark") ?? "") ?? .wenkai

    private(set) var code: Pref.Code = Pref.Code(rawValue: UserDefaults.standard.string(forKey: "look.code") ?? "") ?? .maple

    func setCode(_ value: Pref.Code) {
        if code != value { code = value }
        writeDefaults { UserDefaults.standard.set(value.rawValue, forKey: "look.code") }
    }

    func setFace(_ value: Pref.Face) {
        if face != value { face = value }
        writeDefaults { UserDefaults.standard.set(value.rawValue, forKey: "look.face") }
    }

    func setMark(_ value: Pref.Face) {
        if mark != value { mark = value }
        writeDefaults { UserDefaults.standard.set(value.rawValue, forKey: "look.mark") }
    }

    func pick(_ key: String) {
        if self.key != key { self.key = key }
        writeDefaults { UserDefaults.standard.set(key, forKey: "look.accent") }
    }

    func setSize(_ value: Double) {
        if size != value { size = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.size") }
    }

    func setLineHeight(_ value: Double) {
        if lineHeight != value { lineHeight = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.lineHeight") }
    }

    func setParagraphGap(_ value: Double) {
        let snapped = Stops.nearest(value, in: Pref.paragraphGapStops)
        if paragraphGap != snapped { paragraphGap = snapped }
        writeDefaults { UserDefaults.standard.set(snapped, forKey: "look.paragraphGap") }
    }

    func setHeadingWeight(_ value: Pref.HeadingWeight) {
        if headingWeight != value { headingWeight = value }
        writeDefaults { UserDefaults.standard.set(value.rawValue, forKey: "look.headingWeight") }
    }

    func setClreqSqueeze(_ value: Bool) {
        if clreqSqueeze != value { clreqSqueeze = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.clreqSqueeze") }
    }

    func setReadingWidth(_ value: Double) {
        let snapped = Stops.nearest(value, in: Pref.readingWidthStops)
        if readingWidth != snapped { readingWidth = snapped }
        writeDefaults { UserDefaults.standard.set(snapped, forKey: "look.readingWidth") }
    }

    func setUIDensity(_ value: Pref.UIDensity) {
        if uiDensity != value { uiDensity = value }
        writeDefaults { UserDefaults.standard.set(value.rawValue, forKey: "look.uiDensity") }
    }

    func setReduceVisualEffects(_ value: Bool) {
        if reduceVisualEffects != value { reduceVisualEffects = value }
        writeDefaults { UserDefaults.standard.set(value, forKey: "look.reduceVisualEffects") }
    }

    func applyReadingPreset(_ preset: Pref.ReadingPreset) {
        writeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(preset.face.rawValue, forKey: "look.face")
            defaults.set(preset.size, forKey: "look.size")
            defaults.set(preset.lineHeight, forKey: "look.lineHeight")
            defaults.set(preset.paragraphGap, forKey: "look.paragraphGap")
        }
        if face != preset.face { face = preset.face }
        if abs(size - preset.size) > 0.05 { size = preset.size }
        if abs(lineHeight - preset.lineHeight) > 0.01 { lineHeight = preset.lineHeight }
        if abs(paragraphGap - preset.paragraphGap) > 0.1 { paragraphGap = preset.paragraphGap }
    }

    func resetReadingTypography() {
        writeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(17.0, forKey: "look.size")
            defaults.set(Pref.defaultLineHeight, forKey: "look.lineHeight")
            defaults.set(Pref.defaultParagraphGap, forKey: "look.paragraphGap")
            defaults.set(Pref.HeadingWeight.semibold.rawValue, forKey: "look.headingWeight")
            defaults.set(true, forKey: "look.clreqSqueeze")
            defaults.set(Pref.defaultReadingWidth, forKey: "look.readingWidth")
        }
        if size != 17.0 { size = 17.0 }
        if lineHeight != Pref.defaultLineHeight { lineHeight = Pref.defaultLineHeight }
        if paragraphGap != Pref.defaultParagraphGap { paragraphGap = Pref.defaultParagraphGap }
        if headingWeight != .semibold { headingWeight = .semibold }
        if !clreqSqueeze { clreqSqueeze = true }
        if readingWidth != Pref.defaultReadingWidth { readingWidth = Pref.defaultReadingWidth }
    }

    func resetLook() {
        writeDefaults {
            let defaults = UserDefaults.standard
            defaults.set("system", forKey: "look.scheme")
            defaults.set("dai", forKey: "look.accent")
            defaults.set(false, forKey: "look.oled")
            defaults.set(false, forKey: "look.white")
            defaults.set("", forKey: "look.bubble")
        }
        if key != "dai" { key = "dai" }
        if oled { oled = false }
        if white { white = false }
        if !bubble.isEmpty { bubble = "" }
        if scheme != "system" {
            scheme = "system"
            applyScheme()
        }
    }

    func resetFonts() {
        writeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(Pref.Face.serif.rawValue, forKey: "look.face")
            defaults.set(Pref.Face.wenkai.rawValue, forKey: "look.mark")
            defaults.set(Pref.Code.maple.rawValue, forKey: "look.code")
        }
        if face != .serif { face = .serif }
        if mark != .wenkai { mark = .wenkai }
        if code != .maple { code = .maple }
    }

    var palette: Ink.Palette { Ink.palette(for: key) }

    // Reading size, line height and light / dark: set from several pages with `@AppStorage`, read everywhere through
    // `Pref`. Kept here so every view that read them is drawn again the moment they change — before, only the reply
    // text followed a new size, and other sheets kept the old light or dark until reopened.
    private(set) var size: Double = Theme.number("look.size", 17)
    private(set) var lineHeight: Double = Theme.number("look.lineHeight", Pref.defaultLineHeight)
    private(set) var paragraphGap: Double = Theme.snappedNumber("look.paragraphGap", stops: Pref.paragraphGapStops, fallback: Pref.defaultParagraphGap)
    private(set) var headingWeight: Pref.HeadingWeight = Pref.HeadingWeight(rawValue: UserDefaults.standard.string(forKey: "look.headingWeight") ?? "") ?? .semibold
    private(set) var clreqSqueeze: Bool = UserDefaults.standard.object(forKey: "look.clreqSqueeze") as? Bool ?? true
    private(set) var readingWidth: Double = Theme.snappedNumber("look.readingWidth", stops: Pref.readingWidthStops, fallback: Pref.defaultReadingWidth)
    private(set) var uiDensity: Pref.UIDensity = Pref.UIDensity(rawValue: UserDefaults.standard.string(forKey: "look.uiDensity") ?? "") ?? .standard
    private(set) var reduceVisualEffects: Bool = UserDefaults.standard.bool(forKey: "look.reduceVisualEffects")
    private(set) var fade: Bool = UserDefaults.standard.object(forKey: "look.fade") as? Bool ?? true
    private(set) var scheme: String = UserDefaults.standard.string(forKey: "look.scheme") ?? "system"
    @ObservationIgnored private var watching: NSObjectProtocol?
    @ObservationIgnored private var isWritingDefaults = false
    /// Bumped when 宋体 or 楷体 finishes downloading, so text already drawn in the stand-in face is drawn again in it.
    private(set) var fontsArrived = 0
    func fontArrived() { fontsArrived += 1 }

    init() {
        watching = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in
                    self?.refresh()
                }
                return
            }
            guard let self, !self.isWritingDefaults else { return }
            self.refresh()
        }
    }

    private func writeDefaults(_ update: () -> Void) {
        isWritingDefaults = true
        defer { isWritingDefaults = false }
        update()
    }

    private static func number(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    private static func snappedNumber(_ key: String, stops: [Double], fallback: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return Stops.nearest(UserDefaults.standard.double(forKey: key), in: stops)
    }

    private func refresh() {
        let defaults = UserDefaults.standard
        let size = Self.number("look.size", 17)
        if size != self.size { self.size = size }
        let line = Self.number("look.lineHeight", Pref.defaultLineHeight)
        if line != lineHeight { lineHeight = line }
        let nextGap = Self.snappedNumber("look.paragraphGap", stops: Pref.paragraphGapStops, fallback: Pref.defaultParagraphGap)
        if nextGap != paragraphGap { paragraphGap = nextGap }
        let nextWeight = Pref.HeadingWeight(rawValue: defaults.string(forKey: "look.headingWeight") ?? "") ?? .semibold
        if nextWeight != headingWeight { headingWeight = nextWeight }
        let nextSqueeze = defaults.object(forKey: "look.clreqSqueeze") as? Bool ?? true
        if nextSqueeze != clreqSqueeze { clreqSqueeze = nextSqueeze }
        let nextWidth = Self.snappedNumber("look.readingWidth", stops: Pref.readingWidthStops, fallback: Pref.defaultReadingWidth)
        if nextWidth != readingWidth { readingWidth = nextWidth }
        let nextDensity = Pref.UIDensity(rawValue: defaults.string(forKey: "look.uiDensity") ?? "") ?? .standard
        if nextDensity != uiDensity { uiDensity = nextDensity }
        let nextReduceVisual = defaults.bool(forKey: "look.reduceVisualEffects")
        if nextReduceVisual != reduceVisualEffects { reduceVisualEffects = nextReduceVisual }
        let nextKey = defaults.string(forKey: "look.accent") ?? "dai"
        if nextKey != key { key = nextKey }
        let nextPlain = defaults.bool(forKey: "look.plainNames")
        if nextPlain != plain { plain = nextPlain }
        let nextHint = defaults.object(forKey: "look.toneHint") as? Bool ?? true
        if nextHint != hint { hint = nextHint }
        let nextOled = defaults.bool(forKey: "look.oled")
        if nextOled != oled { oled = nextOled }
        let nextWhite = defaults.bool(forKey: "look.white")
        if nextWhite != white { white = nextWhite }
        let nextBubble = defaults.string(forKey: "look.bubble") ?? ""
        if nextBubble != bubble { bubble = nextBubble }
        let nextFace = Pref.Face(rawValue: defaults.string(forKey: "look.face") ?? "") ?? .serif
        if nextFace != face { face = nextFace }
        let nextMark = Pref.Face(rawValue: defaults.string(forKey: "look.mark") ?? "") ?? .wenkai
        if nextMark != mark { mark = nextMark }
        let nextCode = Pref.Code(rawValue: defaults.string(forKey: "look.code") ?? "") ?? .maple
        if nextCode != code { code = nextCode }
        let nextFade = defaults.object(forKey: "look.fade") as? Bool ?? true
        if nextFade != fade { fade = nextFade }
        let scheme = defaults.string(forKey: "look.scheme") ?? "system"
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
        if theme.white { return theme.oled ? palette.paperWhiteOled : palette.paperWhite }
        return theme.oled ? palette.paperOled : palette.paper
    }
    static var paperRaised: Color {
        let theme = Theme.shared, palette = theme.palette
        if theme.white { return theme.oled ? palette.raisedWhiteOled : palette.raisedWhite }
        return theme.oled ? palette.raisedOled : palette.raised
    }
    static let ink = pair(0x1F1E1B, 0xEFEAE0)
    static let inkSoft = pair(0x57534A, 0xB9B1A2)
    static let inkFaint: Color = Color(UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        let hex: UInt32
        if traits.accessibilityContrast == .high {
            hex = isDark ? 0xB9B1A2 : 0x57534A
        } else {
            hex = isDark ? 0x989082 : 0x696459
        }
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    })
    /// 朱: the seal's cinnabar for strokes/text and fill ground. Only for the seal.
    static let seal = pair(0xB5382A, 0xE87568)
    static let sealFill = pair(0xB5382A, 0xB84134)

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

    /// Code in a reply, from the same pigments as everything else; calibrated AA against code surfaces.
    enum Code {
        static let keyword = pair(0x5E478C, 0xB8A6DE)
        static let function = pair(0x2E587D, 0x8EB6DB)
        static let string = pair(0x286644, 0x84C498)
        static let number = pair(0x8A560B, 0xE0AE60)
        /// A block of what a program printed, not code to read.
        static let output = pair(0x286644, 0x84C498)
    }

    /// A failure in the conversation: the card's ground.
    static let stopWash = pair(0xF5E2DF, 0x3D2624)
    /// Subtle surface well inside paper/cards (tags, inline code, table headers).
    static var surfaceSubtle: Color {
        Theme.shared.oled ? pair(0xEFEAE0, 0x1C1A17) : pair(0xEFEAE0, 0x2C2924)
    }
    /// Ground for multi-line code blocks, decoupled from paper and message bubbles.
    static var codeBg: Color {
        Theme.shared.oled ? pair(0xF1ECE1, 0x141310) : pair(0xF1ECE1, 0x1F1D19)
    }

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
        return theme.white ? palette.ruleWhite : palette.rule
    }
    /// The accent, its foreground contrast ink, and its pale ground, from the palette the user picked.
    static var accent: Color { Theme.shared.palette.accent }
    static var onAccent: Color { Theme.shared.palette.onAccent }
    static var accentWash: Color { Theme.shared.palette.wash }

    struct Palette: Identifiable {
        var key: String
        var title: String
        var accent: Color
        var onAccent: Color
        /// The accent as a tile ground: the light-mode accent in both modes.
        var tile: Color
        var wash: Color
        var paper: Color
        var paperWhite: Color
        var paperOled: Color
        var paperWhiteOled: Color
        var raised: Color
        var raisedWhite: Color
        var raisedOled: Color
        var raisedWhiteOled: Color
        var rule: Color
        var ruleWhite: Color
        var mine: Color
        var mineWhite: Color
        /// The light-mode paper, for the pure-black dark mode that keeps the light one as it is.
        var paperLight: UInt32
        var raisedLight: UInt32
        var paperDark: UInt32
        var raisedDark: UInt32
        var ruleDark: UInt32
        var mineDark: UInt32
        var id: String { key }

        /// `light` and `dark` are the accent in both modes; `tint` is how much of it the neutrals take (0 for none).
        init(key: String, title: String, light: UInt32, dark: UInt32, wash: Color, onAccent: Color = Ink.pair(0xFFFDF8, 0x14181E), tint: Double) {
            self.key = key
            self.title = title
            self.accent = Ink.pair(light, dark)
            self.onAccent = onAccent
            self.tile = Ink.pair(light, Ink.mix(light, 0xFFFFFF, 0.08))
            self.wash = wash
            paperLight = Ink.mix(0xF8F5EE, light, 0.05 * tint)
            raisedLight = Ink.mix(0xFFFDF8, light, 0.035 * tint)
            paperDark = Ink.mix(0x191815, dark, 0.05 * tint)
            raisedDark = Ink.mix(0x23211D, dark, 0.035 * tint)
            ruleDark = Ink.mix(0x3A362F, dark, 0.08 * tint)
            mineDark = Ink.mix(0x312D26, dark, 0.07 * tint)
            paper = Ink.pair(paperLight, paperDark)
            paperWhite = Ink.pair(0xFFFFFF, paperDark)
            paperOled = Ink.pair(paperLight, 0x000000)
            paperWhiteOled = Ink.pair(0xFFFFFF, 0x000000)
            raised = Ink.pair(raisedLight, raisedDark)
            raisedWhite = Ink.pair(0xF4F4F5, raisedDark)
            raisedOled = Ink.pair(raisedLight, 0x12110F)
            raisedWhiteOled = Ink.pair(0xF4F4F5, 0x12110F)
            rule = Ink.pair(Ink.mix(0xE2DACB, light, 0.08 * tint), ruleDark)
            ruleWhite = Ink.pair(0xE4E4E7, ruleDark)
            mine = Ink.pair(Ink.mix(0xEAE2D3, light, 0.07 * tint), mineDark)
            mineWhite = Ink.pair(0xEFEFF1, mineDark)
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

    /// 主色: ink colors with old names. 黛 (素笺黛蓝) is the first and the default; 竹 carries 栖息松绿.
    static let palettes: [Palette] = [
        Palette(key: "dai", title: "黛", light: 0x35587B, dark: 0x8CB4DB, wash: pair(0xE2EAF2, 0x253443), onAccent: pair(0xFFFDF8, 0x14181E), tint: 0),
        Palette(key: "yan", title: "胭", light: 0x9E3E38, dark: 0xE38E86, wash: pair(0xF4E2DF, 0x3D2928), onAccent: pair(0xFFFDF8, 0x1E1211), tint: 1),
        Palette(key: "zhu", title: "竹", light: 0x276454, dark: 0x70BFAA, wash: pair(0xDFECE7, 0x203630), onAccent: pair(0xFCFAF6, 0x0E1A16), tint: 1),
        Palette(key: "xiang", title: "缃", light: 0x855B10, dark: 0xDFB15B, wash: pair(0xF3E8D2, 0x3A301F), onAccent: pair(0xFFFDF8, 0x1D160B), tint: 0.6),
        Palette(key: "teng", title: "藤", light: 0x624D8A, dark: 0xB39FD9, wash: pair(0xEAE4F3, 0x312940), onAccent: pair(0xFFFDF8, 0x16121F), tint: 1),
        Palette(key: "mo", title: "墨", light: 0x363430, dark: 0xCFC8BB, wash: pair(0xE9E5DE, 0x32302C), onAccent: pair(0xFFFDF8, 0x191815), tint: 0.5),
    ]
    private static let paletteMap: [String: Palette] = Dictionary(uniqueKeysWithValues: palettes.map { ($0.key, $0) })
    static func palette(for key: String) -> Palette { paletteMap[key] ?? palettes[0] }
    /// Your own bubbles: the paper's tint, or a soft wash of the colour you picked (text stays plain ink, so it
    /// always reads).
    static var bubble: Color {
        let theme = Theme.shared
        guard !theme.bubble.isEmpty, let picked = paletteMap[theme.bubble] else { return mine }
        return picked.wash
    }
    static var mine: Color {
        let theme = Theme.shared, palette = theme.palette
        return theme.white ? palette.mineWhite : palette.mine
    }
    static let ok = pair(0x286644, 0x6EC08E)
    static let warn = pair(0x945608, 0xE4A952)
    static let stop = pair(0xB4322A, 0xEC7E75)

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
    static func recheckFonts() {
        fonts.removeAllObjects()
        monoFonts.removeAllObjects()
        uiFaces.removeAllObjects()
    }

    private static let fonts = NSCache<NSString, NSNumber>()
    private static let monoFonts = NSCache<NSString, UIFont>()
    private static let uiFaces = NSCache<NSString, UIFont>()

    /// The reading face as a UIKit font, for native selectable text and line-height metrics.
    static func uiFace(_ size: CGFloat, bold: Bool = false, face: Pref.Face? = nil) -> UIFont {
        uiFace(size, weight: bold ? .semibold : .regular, face: face)
    }

    static func uiFace(_ size: CGFloat, weight: UIFont.Weight, face: Pref.Face? = nil) -> UIFont {
        let current = face ?? Pref.face
        if current.downloads { _ = Theme.shared.fontsArrived }
        let isBold = weight.rawValue >= UIFont.Weight.semibold.rawValue
        let key = "\(current.rawValue)|\(String(format: "%.3f", weight.rawValue))|\(size)" as NSString
        if let cached = uiFaces.object(forKey: key) { return cached }
        let resolved: UIFont
        if let name = current.postScript(bold: isBold), has(name), let font = UIFont(name: name, size: size) {
            resolved = font
        } else {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let design: UIFontDescriptor.SystemDesign
            switch current {
            case .sans: design = .default
            case .rounded: design = .rounded
            default: design = .serif
            }
            if let described = base.fontDescriptor.withDesign(design) {
                resolved = UIFont(descriptor: described, size: size)
            } else {
                resolved = base
            }
        }
        uiFaces.setObject(resolved, forKey: key)
        return resolved
    }

    /// Any face at any size; a face not on the phone yet stands in as the system serif.
    static func face(_ face: Pref.Face, _ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        Self.face(face, size, weight: bold ? .semibold : .regular, relativeTo: style)
    }

    static func face(_ face: Pref.Face, _ size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle = .body) -> Font {
        if face.downloads { _ = Theme.shared.fontsArrived }
        let isBold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
        if let name = face.postScript(bold: isBold), has(name) {
            return .custom(name, size: size, relativeTo: style)
        }
        switch face {
        case .sans: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        default: return .system(size: size, weight: weight, design: .serif)
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
    static func uiMono(_ size: CGFloat, bold: Bool = false, preference: Pref.Code? = nil) -> UIFont {
        if (preference ?? Pref.code) == .maple, let font = mapleWithChinese(size, bold: bold) { return font }
        return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// Code blocks use a half-em ASCII cell and the system's natural full-em CJK glyphs.
    @MainActor static func codeBlockFonts(size: CGFloat? = nil, preference: Pref.Code? = nil) -> (narrow: Font, wide: Font) {
        let resolvedSize = size ?? CGFloat(max(12, Pref.size - 3))
        let resolvedPreference = preference ?? Pref.code
        if let cached = codeBlockFontCache, cached.size == resolvedSize, cached.preference == resolvedPreference { return cached.fonts }
        let mono = (resolvedPreference == .maple ? UIFont(name: "MapleMono-Regular", size: resolvedSize) : nil)
            ?? UIFont.monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        let native = mono as CTFont
        var zero: UniChar = 48
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(native, &zero, &glyph, 1) else {
            return (Font(mono), .system(size: resolvedSize))
        }
        let advance = CTFontGetAdvancesForGlyphs(native, .horizontal, &glyph, nil, 1)
        guard advance > 0 else { return (Font(mono), .system(size: resolvedSize)) }
        var matrix = CGAffineTransform(scaleX: resolvedSize * 0.5 / advance, y: 1)
        let half = CTFontCreateCopyWithAttributes(native, resolvedSize, &matrix, nil)
        let fonts = (narrow: Font(half), wide: Font.system(size: resolvedSize))
        codeBlockFontCache = (resolvedSize, resolvedPreference, fonts)
        return fonts
    }

    @MainActor private static var codeBlockFontCache: (size: CGFloat, preference: Pref.Code, fonts: (narrow: Font, wide: Font))?


    /// Maple Mono, with Clio Mono CN behind it for Chinese: every Chinese character exactly two letters wide, so
    /// columns of output and code line up even with Chinese in them (Maple Mono CN, cut to GB2312).
    private static func mapleWithChinese(_ size: CGFloat, bold: Bool) -> UIFont? {
        let key = "\(bold ? 1 : 0)|\(size)" as NSString
        if let cached = monoFonts.object(forKey: key) { return cached }
        let name = bold ? "MapleMono-SemiBold" : "MapleMono-Regular"
        guard has(name), let latin = UIFont(name: name, size: size) else { return nil }
        let resolved: UIFont
        if has("ClioMonoCN-Regular") {
            let chinese = UIFontDescriptor(fontAttributes: [.name: "ClioMonoCN-Regular"])
            resolved = UIFont(descriptor: latin.fontDescriptor.addingAttributes([.cascadeList: [chinese]]), size: size)
        } else {
            resolved = latin
        }
        monoFonts.setObject(resolved, forKey: key)
        return resolved
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

    /// The space between the lines of reading text (`SafeLineBox` single source of truth).
    static var leading: CGFloat { Pref.leading }
    static func leading(size: Double, lineHeight: Double, face: Pref.Face) -> CGFloat {
        SafeLineBox.resolve(userSize: CGFloat(size), contentMultiplier: CGFloat(lineHeight), face: face).swiftUILineSpacing
    }
    /// Between paragraphs: configurable stop (`paragraphGap`), defaulting to `13pt` at standard reading scale.
    static var paragraphGap: CGFloat { CGFloat(Theme.shared.paragraphGap) }

    private static func adaptiveWhite(_ light: CGFloat, dark: CGFloat) -> Color {
        Color(UIColor { traits in
            UIColor(white: 1, alpha: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func adaptiveBlack(_ light: CGFloat, dark: CGFloat) -> Color {
        Color(UIColor { traits in
            UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let bubbleSheenTop = adaptiveWhite(0.22, dark: 0.06)
    static let bubbleSheenBottom = Color.white.opacity(0)
    static let bubbleBorderTop = adaptiveWhite(0.55, dark: 0.16)
    static let bubbleBorderMid = adaptiveWhite(0.10, dark: 0.04)
    static let bubbleShadow = adaptiveBlack(0.06, dark: 0.22)

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
        static let instant = Animation.spring(response: 0.18, dampingFraction: 0.88)
        static let quick = Animation.spring(response: 0.26, dampingFraction: 0.85)
        static let standard = Animation.spring(response: 0.36, dampingFraction: 0.84)
        static let expressive = Animation.spring(response: 0.48, dampingFraction: 0.72)

        static let press = instant
        static let unfold = standard
        static let settle = quick

        static func prefersReduced(_ systemReduceMotion: Bool) -> Bool {
            systemReduceMotion || Theme.shared.reduceVisualEffects
        }
    }
}

/// Anything tappable: gives a little under the finger and springs back cleanly; stays silent unless opted in.
struct PressStyle: ButtonStyle {
    var haptic = false
    var elevated = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let reduce = accessibilityReduceMotion || Theme.shared.reduceVisualEffects
        let pressed = configuration.isPressed
        styledLabel(configuration.label, pressed: pressed, reduce: reduce)
            .scaleEffect(pressed && !reduce ? 0.97 : 1)
            .opacity(pressed ? 0.85 : 1)
            .animation(reduce ? .easeOut(duration: 0.12) : Ink.Motion.press, value: pressed)
            .onChange(of: pressed) { _, isPressed in
                if isPressed, haptic { Haptics.tick(0.5) }
            }
    }

    @ViewBuilder
    private func styledLabel(_ label: Configuration.Label, pressed: Bool, reduce: Bool) -> some View {
        if elevated {
            label
                .shadow(
                    color: Ink.bubbleShadow.opacity(pressed ? 0.35 : 0.75),
                    radius: pressed ? 3 : 8,
                    y: pressed ? 1 : 3
                )
                // The whole frame takes the tap, not just the drawn strokes and glyphs.
                .contentShape(Rectangle())
                .offset(y: pressed && !reduce ? 1 : 0)
        } else {
            label
                // The whole frame takes the tap, not just the drawn strokes and glyphs.
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// A card that reads as paper: a raised sheet with a hairline edge.
    func paperCard(radius: CGFloat = Ink.Radius.card) -> some View {
        modifier(PaperCardModifier(radius: radius))
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
        modifier(GlassFaceModifier(shape: shape))
    }

    /// Your message bubble: a touch of glass, without the cost of real glass on every bubble in a long chat.
    /// The paper tint, a light catching the top edge, a hairline and a soft shadow under it.
    func glassBubble<S: InsettableShape>(in shape: S, tint: Color) -> some View {
        background {
            ZStack {
                shape.fill(tint)
                    .shadow(color: Ink.bubbleShadow, radius: 10, y: 3)
                shape.fill(LinearGradient(colors: [Ink.bubbleSheenTop, Ink.bubbleSheenBottom],
                                          startPoint: .top, endPoint: .center))
                shape.strokeBorder(LinearGradient(colors: [Ink.bubbleBorderTop, Ink.bubbleBorderMid, Ink.rule],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
        }
    }

    /// Liquid Glass behind a bar that holds its own controls (the composer, an address bar). The clear layer sits
    /// between the glass and the controls: taps between them land on it instead of on the glass.
    func glassBacking<S: Shape>(in shape: S) -> some View {
        modifier(GlassBackingModifier(shape: shape))
    }

    /// Anti-bleed Liquid Glass backing for the bottom composer shell so scrolled chat text
    /// cannot read through into the input prompt while preserving glass depth.
    func composerGlassBacking<S: InsettableShape>(in shape: S) -> some View {
        modifier(ComposerGlassBackingModifier(shape: shape))
    }
}

private struct PaperCardModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(Ink.paperRaised)
                    .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
            }
            .overlay {
                shape
                    .strokeBorder(Ink.rule.opacity(contrast == .increased ? 1 : 0.7), lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct GlassFaceModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let solid = reduceTransparency || Theme.shared.reduceVisualEffects
        if solid {
            content
                .background { shape.fill(Ink.paperRaised) }
                .overlay {
                    shape.stroke(Ink.rule, lineWidth: contrast == .increased ? 1 : 0.75)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
                .contentShape(shape)
        } else {
            content
                .glassEffect(.regular, in: shape)
                .overlay { shape.fill(Color.white.opacity(0.001)) }
                .contentShape(shape)
        }
    }
}

private struct GlassBackingModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let solid = reduceTransparency || Theme.shared.reduceVisualEffects
        if solid {
            content
                .background { shape.fill(Ink.paperRaised) }
                .overlay {
                    shape.stroke(Ink.rule, lineWidth: contrast == .increased ? 1 : 0.75)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background { shape.fill(Color.white.opacity(0.001)) }
                .glassEffect(.regular, in: shape)
        }
    }
}

private struct ComposerGlassBackingModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let solid = reduceTransparency || Theme.shared.reduceVisualEffects
        let lineWidth: CGFloat = (contrast == .increased || solid) ? 1 : 0.5
        let ruleOpacity: Double = contrast == .increased ? 1 : (solid ? 0.8 : 0.45)
        if solid {
            content
                .background { shape.fill(Ink.paperRaised) }
                .overlay {
                    shape.strokeBorder(Ink.rule.opacity(ruleOpacity), lineWidth: lineWidth)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background { shape.fill(Color.white.opacity(0.001)) }
                .glassEffect(.regular, in: shape)
                .overlay {
                    shape.strokeBorder(Ink.rule.opacity(ruleOpacity), lineWidth: lineWidth)
                        .allowsHitTesting(false)
                }
        }
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
