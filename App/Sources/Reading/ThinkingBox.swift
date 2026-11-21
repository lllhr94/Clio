import SwiftUI

/// What the model thought before it answered.
/// While it thinks: a small window with the last three lines rolling by, so the person sees it is working
/// and on what. Afterwards: one quiet line "想了 N 字", opened with a tap.
struct ThinkingBox: View {
    let text: String
    var live = false
    @State private var open = false

    private var count: Int { text.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Button {
                guard !live else { return }
                withAnimation(Ink.Motion.settle) { open.toggle() }
                Haptics.tick(0.4)
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "brain")
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .symbolEffect(.pulse, isActive: live)
                    Text(live ? Words.t("正在沉吟") + " · \(count) 字" : Words.t("沉吟") + "了 \(count) 字")
                        .font(Ink.footnote)
                    if !live {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Ink.Size.micro, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.inkFaint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? "正在思考" : "思考了 \(count) 字，点开看")

            if live {
                Text(tail)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .lineLimit(3, reservesSpace: false)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .background(Ink.rule.opacity(0.25), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .mask(LinearGradient(colors: [.black.opacity(0.35), .black], startPoint: .top, endPoint: .center))
                    .animation(.easeOut(duration: 0.2), value: tail)
            } else if open {
                Text(text)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .textSelection(.enabled)
                    .padding(.leading, Ink.Space.m)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Ink.rule).frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
    }

    /// The last few hundred characters, so the window shows the newest lines.
    private var tail: String {
        let cut = text.suffix(220)
        return cut.split(separator: "\n", omittingEmptySubsequences: true).suffix(3).joined(separator: "\n")
    }
}

/// The companion's 心绪 before it spoke (see `Pulse`): folded to one line with how it feels,
/// opened to the four pools. While it is being written, the newest lines show.
struct PulseBox: View {
    let text: String
    var live = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            Button {
                guard !live else { return }
                withAnimation(Ink.Motion.settle) { open.toggle() }
                Haptics.tick(0.4)
            } label: {
                HStack(spacing: 6) {
                    Text("✿").font(.system(size: Ink.Size.small))
                    Text(live ? "心绪" : (Pulse.vibe(text).map { "心绪 · \($0)" } ?? "心绪"))
                        .font(Ink.footnote)
                        .lineLimit(1)
                    if !live {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Ink.Size.micro, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.accent.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(live ? "正在写心绪" : "心绪，点开看")

            if live || open {
                Text(live ? tail : text)
                    .font(.system(size: Ink.Size.small))
                    .foregroundStyle(Ink.inkSoft)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Ink.Space.m)
                    .padding(.vertical, Ink.Space.s)
                    .background(Ink.accentWash, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
                    .transition(.opacity)
            }
        }
    }

    private var tail: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
    }
}
