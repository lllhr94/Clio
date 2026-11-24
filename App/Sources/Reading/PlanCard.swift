import SwiftUI

/// The steps a companion laid out for a longer task, above the composer: 「2/6 · 下一步：…」 with a thin progress
/// line, opened to the whole list. Done steps are ticked, the one in hand is ringed.
struct PlanCard: View {
    let steps: [TeamModel.PlanStep]
    var maxHeight: CGFloat? = nil
    var close: () -> Void
    @State private var open = false
    @State private var detailsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Int { steps.filter { $0.state == "done" }.count }
    private var current: TeamModel.PlanStep? { steps.first { $0.state == "doing" } ?? steps.first { $0.state != "done" } }

    var body: some View {
        PlanReveal(progress: open ? 1 : 0, maxHeight: maxHeight, naturalDetailsHeight: detailsHeight) {
            Button {
                Haptics.tick(0.4)
                withAnimation(reduceMotion ? nil : Ink.Motion.unfold) { open.toggle() }
            } label: {
                HStack(spacing: Ink.Space.s) {
                    Image(systemName: "checklist").font(.system(size: Ink.Size.sub, weight: .medium)).foregroundStyle(Ink.inkSoft)
                    Text(headline)
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                    Spacer(minLength: Ink.Space.s)
                    Capsule().fill(Ink.rule).frame(width: 44, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Ink.accent).frame(width: 44 * CGFloat(done) / CGFloat(max(1, steps.count)), height: 4)
                        }
                    Image(systemName: "chevron.down")
                        .font(.system(size: Ink.Size.micro, weight: .bold))
                        .foregroundStyle(Ink.inkFaint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, Ink.Space.l)
                .padding(.vertical, Ink.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清单，做完 \(done) 步，共 \(steps.count) 步")
            .accessibilityValue(L.t(open ? "chat.planExpanded" : "chat.planCollapsed"))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Ink.Space.m) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: Ink.Space.m) {
                            mark(step.state)
                            Text(step.text)
                                .font(.system(size: Ink.Size.sub, weight: step.state == "doing" ? .semibold : .regular))
                                .foregroundStyle(step.state == "done" ? Ink.inkFaint : Ink.ink)
                                .strikethrough(step.state == "done", color: Ink.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if done == steps.count {
                        Button("收起清单") { close() }
                            .font(.system(size: Ink.Size.small, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Ink.Space.l)
                .padding(.bottom, Ink.Space.l)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
        }
        .clipShape(.rect(cornerRadius: Ink.Radius.card, style: .continuous))
        .paperCard()
        .animation(reduceMotion ? nil : Ink.Motion.settle, value: steps)
    }

    private var headline: String {
        if done == steps.count { return "\(done)/\(steps.count) · 都做完了" }
        return "\(done)/\(steps.count) · 下一步：\(current?.text ?? "")"
    }

    @ViewBuilder
    private func mark(_ state: String) -> some View {
        switch state {
        case "done":
            Image(systemName: "checkmark.circle.fill").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.ok)
        case "doing":
            Image(systemName: "circle.circle").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.accent)
                .symbolEffect(.pulse)
        default:
            Image(systemName: "circle").font(.system(size: Ink.Size.body)).foregroundStyle(Ink.inkFaint)
        }
    }
}

/// Only the card's height animates. Its fully laid-out rows are revealed by the card's clip, capped at `maxHeight`.
private struct PlanReveal: Layout {
    var progress: CGFloat
    var maxHeight: CGFloat?
    var naturalDetailsHeight: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func cappedDetails(header: CGFloat, fallback: CGFloat) -> CGFloat {
        let raw = naturalDetailsHeight > 0 ? naturalDetailsHeight : fallback
        guard let maxHeight else { return raw }
        let limit = max(72, maxHeight - header)
        return min(raw, limit)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let row = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(row).height
        let fallback = subviews[1].sizeThatFits(row).height
        let details = cappedDetails(header: header, fallback: fallback)
        return CGSize(width: width, height: header + details * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = ProposedViewSize(width: bounds.width, height: nil)
        let header = subviews[0].sizeThatFits(row).height
        let fallback = subviews[1].sizeThatFits(row).height
        let details = cappedDetails(header: header, fallback: fallback)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: row)
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + header),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: details)
        )
    }
}
