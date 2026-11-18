import Observation
import SwiftUI
import UIKit

/// The accent the user picked in 纸墨与絮语. Ink reads it, so every view drawn with the accent redraws when it changes.
@Observable
final class Theme {
    static let shared = Theme()

    private(set) var key: String = UserDefaults.standard.string(forKey: "look.accent") ?? "dai"

    func pick(_ key: String) {
        self.key = key
        UserDefaults.standard.set(key, forKey: "look.accent")
    }

    var palette: Ink.Palette { Ink.palettes.first { $0.key == key } ?? Ink.palettes[0] }
}

/// Clio's design system: every color, type size, space and corner comes from here.
enum Ink {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
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

    static let paper = pair(0xF6F1E7, 0x1C1A17)
    static let paperRaised = pair(0xFBF8F1, 0x26231F)
    static let ink = pair(0x2B2A27, 0xECE6DA)
    static let inkSoft = pair(0x6F6A60, 0xA39C8E)
    static let inkFaint = pair(0xA8A294, 0x6E685D)
    static let rule = pair(0xE4DCCB, 0x37332D)
    /// The accent and its pale ground, from the palette the user picked.
    static var accent: Color { Theme.shared.palette.accent }
    static var accentWash: Color { Theme.shared.palette.wash }

    struct Palette: Identifiable {
        var key: String
        var title: String
        var accent: Color
        var wash: Color
        var id: String { key }
    }

    /// 主色: ink colors with old names. 黛 is the first and the default.
    static let palettes: [Palette] = [
        Palette(key: "dai", title: "黛", accent: pair(0x4A6A8A, 0x8FB0CF), wash: pair(0xE3EAF0, 0x2A3642)),
        Palette(key: "yan", title: "胭", accent: pair(0xA4504A, 0xD98C84), wash: pair(0xF2E1DE, 0x3D2B29)),
        Palette(key: "zhu", title: "竹", accent: pair(0x4F7A5A, 0x8DBB97), wash: pair(0xE1ECE3, 0x283A2D)),
        Palette(key: "xiang", title: "缃", accent: pair(0x93702F, 0xD2AA62), wash: pair(0xF3E8D2, 0x3D3322)),
        Palette(key: "teng", title: "藤", accent: pair(0x6E5A92, 0xA996CF), wash: pair(0xE9E4F2, 0x332C42)),
        Palette(key: "mo", title: "墨", accent: pair(0x3F3D39, 0xC9C2B5), wash: pair(0xE8E5DF, 0x35332F)),
    ]
    static let mine = pair(0xECE4D3, 0x322E28)
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

    /// Whether the system's Songti is there; the serif system face stands in when it is not.
    static let hasSongti = UIFont(name: "STSongti-SC-Regular", size: 17) != nil

    /// The reading face: titles, a companion's words, notes.
    static func serif(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        if hasSongti {
            return .custom(bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size, relativeTo: style)
        }
        return .system(size: size, weight: bold ? .bold : .regular, design: .serif)
    }

    static let display = serif(30, bold: true, relativeTo: .largeTitle)
    static let title = serif(22, bold: true, relativeTo: .title2)
    /// Reading text, in the face and size the user picked in 纸墨.
    static var reading: Font { body(Pref.size, bold: false) }
    static var readingBold: Font { body(Pref.size, bold: true) }

    static func body(_ size: Double, bold: Bool) -> Font {
        switch Pref.face {
        case .song: serif(size, bold: bold, relativeTo: .body)
        case .sans: .system(size: size, weight: bold ? .semibold : .regular)
        case .rounded: .system(size: size, weight: bold ? .semibold : .regular, design: .rounded)
        case .serif: .system(size: size, weight: bold ? .semibold : .regular, design: .serif)
        }
    }
    static let label = Font.system(size: 16, weight: .medium)
    static let secondary = Font.system(size: 14)
    static let footnote = Font.system(size: 12)
    static let code = Font.system(size: 14, design: .monospaced)

    /// The space between the lines of reading text.
    static var leading: CGFloat { Pref.leading }

    // MARK: Space and corners

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let huge: CGFloat = 48
        /// The page's side margin.
        static let page: CGFloat = 20
    }

    /// Floating controls over a page (the top bar, the composer, chips): one height, one distance from the edges,
    /// so what sits side by side lines up and both sides mirror each other.
    enum Bar {
        static let height: CGFloat = 44
        static let edge: CGFloat = 12
    }

    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 14
        static let sheet: CGFloat = 22
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
        background(Ink.paperRaised, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Ink.rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
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
