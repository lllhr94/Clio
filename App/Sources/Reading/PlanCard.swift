import SwiftUI

/// The steps a companion laid out for a longer task, above the composer: 「2/6 · 下一步：…」 with a thin progress
/// line, opened to the whole list. Done steps are ticked, the one in hand is ringed.
struct PlanCard: View {
    let steps: [TeamModel.PlanStep]
    var close: () -> Void
    @State private var open = false

    private var done: Int { steps.filter { $0.state == "done" }.count }
    private var current: TeamModel.PlanStep? { steps.first { $0.state == "doing" } ?? steps.first { $0.state != "done" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tick(0.4)
                withAnimation(Ink.Motion.unfold) { open.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "checklist").font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.inkSoft)
                    Text(headline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Spacer(minLength: Ink.Space.s)
                    Capsule().fill(Ink.rule).frame(width: 44, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Ink.accent).frame(width: 44 * CGFloat(done) / CGFloat(max(1, steps.count)), height: 4)
                        }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, Ink.Space.l)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清单，做完 \(done) 步，共 \(steps.count) 步")

            if open {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.m) {
                            mark(step.state)
                            Text(step.text)
                                .font(.system(size: 14, weight: step.state == "doing" ? .semibold : .regular))
                                .foregroundStyle(step.state == "done" ? Ink.inkFaint : Ink.ink)
                                .strikethrough(step.state == "done", color: Ink.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if done == steps.count {
                        Button("收起清单") { close() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Ink.Space.l)
                .padding(.bottom, Ink.Space.l)
                .transition(.opacity)
            }
        }
        .paperCard()
        .animation(Ink.Motion.settle, value: steps)
    }

    private var headline: String {
        if done == steps.count { return "\(done)/\(steps.count) · 都做完了" }
        return "\(done)/\(steps.count) · 下一步：\(current?.text ?? "")"
    }

    @ViewBuilder
    private func mark(_ state: String) -> some View {
        switch state {
        case "done":
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Ink.ok)
        case "doing":
            Image(systemName: "circle.circle").font(.system(size: 16)).foregroundStyle(Ink.accent)
                .symbolEffect(.pulse)
        default:
            Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(Ink.inkFaint)
        }
    }
}
