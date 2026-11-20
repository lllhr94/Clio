import SwiftUI

// The few pieces every page is built from, so a row in 设置 and a row in 连接器 are the same row.

/// The small square every list row leads with: a symbol on a wash of its tint.
struct IconBadge: View {
    var symbol: String
    var tint: Color = Ink.accent
    var size: CGFloat = Kit.badge

    var body: some View {
        RoundedRectangle(cornerRadius: Kit.iconCorner(size), style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

enum Kit {
    /// The side of a row's leading badge or brand icon.
    static var badge: CGFloat { 30 * UIScale.factor }
    /// Where a row's text starts, so dividers can begin there.
    static var textInset: CGFloat { Ink.Space.l + badge + Ink.Space.m }
    /// A row's height, at the least.
    static var rowHeight: CGFloat { 52 * UIScale.factor }
    /// Every icon tile, whatever its size, has the same proportion of corner: badges, brand icons, service icons.
    static func iconCorner(_ size: CGFloat) -> CGFloat { size * 0.26 }
}

/// What trails a row.
enum RowEnd {
    case none
    case chevron
    case value(String, Color = Ink.inkSoft)
    case valueChevron(String, Color = Ink.inkSoft)
}

/// One list row: something leading, a title, an optional line under it, and what trails.
struct RowLabel<Leading: View>: View {
    var title: String
    /// 日常旁注: the everyday words, small and gray after the title.
    var hint: String? = nil
    var line: String? = nil
    var end: RowEnd = .chevron
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: Ink.Space.m) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
                    Text(title).font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ink)
                    if let hint { Text(hint).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint) }
                }
                .lineLimit(1)
                if let line, !line.isEmpty {
                    Text(line).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft).lineLimit(1)
                }
            }
            Spacer(minLength: Ink.Space.s)
            trailing
        }
        .padding(.horizontal, Ink.Space.l)
        .frame(minHeight: Kit.rowHeight)
        .padding(.vertical, line == nil ? 0 : Ink.Space.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        switch end {
        case .none: EmptyView()
        case .chevron: Kit.chevron
        case .value(let text, let color):
            Text(text).font(.system(size: Ink.Size.sub)).foregroundStyle(color).lineLimit(1)
        case .valueChevron(let text, let color):
            HStack(spacing: Ink.Space.s) {
                Text(text).font(.system(size: Ink.Size.sub)).foregroundStyle(color).lineLimit(1)
                Kit.chevron
            }
        }
    }
}

extension RowLabel where Leading == IconBadge {
    init(_ symbol: String, tint: Color = Ink.accent, title: String, hint: String? = nil, line: String? = nil, end: RowEnd = .chevron) {
        self.init(title: title, hint: hint, line: line, end: end) { IconBadge(symbol: symbol, tint: tint) }
    }
}

extension Kit {
    static var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: Ink.Size.small, weight: .semibold))
            .foregroundStyle(Ink.inkFaint)
    }

    /// The rule between rows of a card, starting where the text starts.
    static var divider: some View { rule(inset: textInset) }

    /// A hairline rule, from `inset` to the trailing edge.
    static func rule(inset: CGFloat = Ink.Space.l) -> some View {
        Rectangle().fill(Ink.rule).frame(height: 0.5).padding(.leading, inset)
    }
}

/// A raised card of rows, with a quiet title over it and an optional note under it.
struct RowCard<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if let title { SectionTitle(title) }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Kit.divider }
                        row
                    }
                }
            }
            .paperCard()
            if let note {
                Text(note)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .padding(.horizontal, Ink.Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The small title over a group, the same everywhere.
struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: Ink.Size.small, weight: .medium))
            .foregroundStyle(Ink.inkSoft)
            .padding(.horizontal, Ink.Space.l)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The one way a button that does the main thing looks: full width, filled, rounded like the cards.
struct WideButtonStyle: ButtonStyle {
    var tint: Color = Ink.accent
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Ink.Size.body, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Ink.Motion.press, value: configuration.isPressed)
    }
}


/// 界面大小: one number every size in Clio is multiplied by (text outside the reading text, spacing, icons, rows,
/// corners). Observable, so every page that read a size is drawn again the moment it changes.
@Observable
final class UIScale {
    static let shared = UIScale()
    static let key = "look.ui"
    static let levels: [(title: String, factor: Double)] = [("紧凑", 0.88), ("偏小", 0.94), ("标准", 1.0), ("偏大", 1.08)]

    var value: Double = {
        let stored = UserDefaults.standard.double(forKey: UIScale.key)
        return stored > 0 ? stored : 1.0
    }() {
        didSet { UserDefaults.standard.set(value, forKey: Self.key) }
    }

    static var factor: CGFloat { CGFloat(shared.value) }
}


extension View {
    /// A block inside running text (code, a table): raised paper with the small corner and a hairline edge.
    /// Cards that hold rows use `paperCard()`; blocks in what you read use this.
    func inkBlock() -> some View {
        background(Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous).strokeBorder(Ink.rule, lineWidth: 0.5))
            .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
    }
}


/// Clio's seal: 克 cut white into cinnabar, a little askew, as a seal pressed by hand is.
/// It stands beside the name at the head of the sidebar and is pressed on what you approve. Its corner is its own:
/// a seal is not a card or a control.
struct ClioSeal: View {
    var size: CGFloat = 22
    var tilt: Double = 0

    var body: some View {
        Text("克")
            .font(.custom("ClioSeal-Regular", size: size * 0.76))
            .foregroundStyle(Ink.sealInk)
            .frame(width: size, height: size)
            .background(Ink.seal, in: .rect(cornerRadius: size * 0.12, style: .continuous))
            .rotationEffect(.degrees(tilt))
            .accessibilityHidden(true)
    }
}

/// A line written over an empty page, between two hairlines, like an inscription on a flyleaf.
struct Inscription: View {
    var text: String

    var body: some View {
        HStack(spacing: Ink.Space.m) {
            Rectangle().fill(Ink.inkFaint).frame(width: 24 * UIScale.factor, height: 0.5)
            Text(text)
                .font(Ink.mark((17 * UIScale.factor).rounded()))
                .foregroundStyle(Ink.inkSoft)
                .multilineTextAlignment(.center)
            Rectangle().fill(Ink.inkFaint).frame(width: 24 * UIScale.factor, height: 0.5)
        }
    }
}
