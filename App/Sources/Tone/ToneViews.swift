import SwiftUI

/// 称谓, as two cards to pick from: what each is like, and a line of the app in that voice. Picking one changes the
/// whole app at once (this page included) and is kept.
struct ToneCards: View {
    var body: some View {
        HStack(spacing: Ink.Space.m) {
            card(plain: true, title: L.daily["styleSwitcher.dailyLabel"] ?? "日常", note: L.daily["onboarding.page3.dailyOptionDesc"] ?? "",
                 sample: "\(L.daily["nav.home"] ?? "") · \(L.daily["loading.thinking"] ?? "")")
            card(plain: false, title: L.literary["styleSwitcher.literaryLabel"] ?? "书卷", note: L.literary["onboarding.page3.literaryOptionDesc"] ?? "",
                 sample: "\(L.literary["nav.home"] ?? "") · \(L.literary["loading.thinking"] ?? "")")
        }
    }

    private func card(plain: Bool, title: String, note: String, sample: String) -> some View {
        let picked = Theme.shared.plain == plain
        return Button {
            Haptics.tick(0.6)
            withAnimation(Ink.Motion.settle) { Theme.shared.setPlain(plain) }
        } label: {
            VStack(alignment: .leading, spacing: Ink.Space.xs) {
                HStack {
                    Text(title).font(.system(size: Ink.Size.body, weight: .semibold)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: Ink.Size.body))
                        .foregroundStyle(picked ? Ink.accent : Ink.inkFaint)
                }
                Text(note).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Ink.Space.xs)
                Text(sample).font(Ink.serif(Ink.Size.sub)).foregroundStyle(Ink.ink.opacity(0.8))
            }
            .padding(Ink.Space.m + 2)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(picked ? Ink.accentWash : Ink.paperRaised, in: .rect(cornerRadius: Ink.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ink.Radius.card, style: .continuous)
                .strokeBorder(picked ? Ink.accent.opacity(0.6) : Ink.rule, lineWidth: picked ? 1.5 : 0.5))
            .contentShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
        }
        .buttonStyle(PressStyle(haptic: false))
        .accessibilityLabel("称谓：\(title)，\(note)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A name with its 日常旁注 beside it, when there is one.
struct Named: View {
    let key: String
    var font: Font = .system(size: Ink.Size.body)
    var color: Color = Ink.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.s) {
            Text(L.t(key)).font(font).foregroundStyle(color)
            if let hint = L.hint(key) {
                Text(hint).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkFaint)
            }
        }
        .lineLimit(1)
    }
}
