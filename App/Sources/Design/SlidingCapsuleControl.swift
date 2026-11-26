import SwiftUI

/// A tactile segmented pill control with a spring-driven sliding thumb and continuous drag selection.
struct SlidingCapsuleControl<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]
    var compact: Bool = false

    @Namespace private var thumbNamespace
    @State private var hoveredIndex: Int?
    @State private var trackWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<Value>, items: [(value: Value, title: String)], compact: Bool = false) {
        self._selection = selection
        self.items = items
        self.compact = compact
    }

    init(
        selection: Binding<Value>,
        options: [Value],
        compact: Bool = false,
        title: @escaping (Value) -> String
    ) {
        self._selection = selection
        self.items = options.map { ($0, title($0)) }
        self.compact = compact
    }

    private var trackHeight: CGFloat {
        (compact ? 30 : 35) * UIScale.factor
    }

    private var labelSize: CGFloat {
        compact ? Ink.Size.micro : Ink.Size.small
    }

    private var transitionAnimation: Animation {
        Ink.Motion.prefersReduced(reduceMotion) ? .easeOut(duration: 0.14) : Ink.Motion.quick
    }

    private var activeIndex: Int? {
        if let hoveredIndex, items.indices.contains(hoveredIndex) {
            return hoveredIndex
        }
        return items.firstIndex { $0.value == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                segmentButton(at: index)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(trackWidth - width) > 0.5 {
                trackWidth = width
            }
        }
        .gesture(dragGesture)
        .padding(3)
        .frame(height: trackHeight)
        .background {
            Capsule(style: .continuous)
                .fill(Ink.surfaceSubtle)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Ink.rule.opacity(0.65), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(Capsule(style: .continuous))
        .onDisappear { hoveredIndex = nil }
    }

    private func segmentButton(at index: Int) -> some View {
        let item = items[index]
        let isActive = activeIndex == index
        return Button {
            select(index: index)
        } label: {
            Text(item.title)
                .font(.system(size: labelSize, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Ink.ink : Ink.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, compact ? Ink.Space.s : Ink.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { thumbBackground(active: isActive) }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func thumbBackground(active: Bool) -> some View {
        if active {
            ZStack {
                Capsule(style: .continuous)
                    .fill(Ink.paperRaised)
                    .shadow(color: Ink.bubbleShadow.opacity(0.55), radius: 3, y: 1)
                Capsule(style: .continuous)
                    .strokeBorder(Ink.rule.opacity(0.5), lineWidth: 0.5)
            }
            .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { drag in
                guard trackWidth > 0, !items.isEmpty else { return }
                if hoveredIndex == nil, abs(drag.translation.height) > abs(drag.translation.width) * 1.2 {
                    return
                }
                let segmentWidth = trackWidth / CGFloat(max(1, items.count))
                let raw = Int((drag.location.x / segmentWidth).rounded(.down))
                let clamped = min(max(raw, 0), items.count - 1)
                if hoveredIndex != clamped {
                    hoveredIndex = clamped
                    select(index: clamped)
                }
            }
            .onEnded { _ in
                hoveredIndex = nil
            }
    }

    private func select(index: Int) {
        guard items.indices.contains(index) else { return }
        let target = items[index].value
        guard selection != target else { return }
        Haptics.selection()
        withAnimation(transitionAnimation) {
            selection = target
        }
    }
}
