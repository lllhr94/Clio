import SwiftUI

/// One choice on a 档位 ruler: what it is, what it is called, and an optional line of detail under the name.
struct Stop<Value: Hashable>: Identifiable {
    let value: Value
    let name: String
    var detail: String? = nil
    var id: Value { value }
}

/// The one way Clio adjusts a number (主人定): a row with the name and the current 档位; tapped, a small card opens
/// with a vertical capsule, filled up to the current stop. Drag along it, or tap a name beside it. The value changes
/// as you drag, so a preview on the page behind follows along. No steppers, no loose sliders.
struct StopRow<Value: Hashable>: View {
    let title: String
    @Binding var value: Value
    let stops: [Stop<Value>]
    /// The detail under the current value in the row, when it helps (like how much that 档位 is for this model).
    var line: String? = nil
    var opensForShot = false
    @State private var open = false

    var body: some View {
        Button {
            Haptics.light()
            open = true
        } label: {
            HStack(spacing: Ink.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Ink.ink)
                    if let line {
                        Text(line).font(Ink.footnote).foregroundStyle(Ink.inkFaint)
                    }
                }
                Spacer(minLength: Ink.Space.s)
                Text(current?.name ?? "").foregroundStyle(Ink.inkSoft).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(Ink.inkFaint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(current?.name ?? "")
        .accessibilityHint("点一下调整")
        .task {
            guard opensForShot else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            open = true
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            StopRuler(title: title, value: $value, stops: stops)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var current: Stop<Value>? { stops.first { $0.value == value } }
}

/// The capsule itself. Stops run from the bottom (the first) to the top (the last), like filling a glass.
struct StopRuler<Value: Hashable>: View {
    var title: String? = nil
    @Binding var value: Value
    let stops: [Stop<Value>]

    /// Long rulers (a pet's ten sizes, a model's eight windows) use shorter stops so the card stays on screen.
    private var step: CGFloat { (stops.count > 6 ? 36 : 44) * UIScale.factor }
    private var width: CGFloat { 52 * UIScale.factor }
    private var index: Int { stops.firstIndex { $0.value == value } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            if let title {
                Text(title).font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkSoft)
            }
            HStack(alignment: .top, spacing: Ink.Space.l) {
                capsule
                names
            }
        }
        .padding(Ink.Space.l)
        .frame(minWidth: 220 * UIScale.factor, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "")
        .accessibilityValue(stops.indices.contains(index) ? stops[index].name : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pick(index + 1)
            case .decrement: pick(index - 1)
            @unknown default: break
            }
        }
    }

    private var capsule: some View {
        let height = step * CGFloat(stops.count)
        let filled = step * CGFloat(index + 1)
        return ZStack(alignment: .bottom) {
            Capsule(style: .continuous).fill(Ink.paperRaised)
            Capsule(style: .continuous)
                .fill(Ink.accent)
                .frame(height: max(width, filled))
            VStack(spacing: 0) {
                ForEach(stops.indices.reversed(), id: \.self) { at in
                    Circle()
                        .fill(at <= index ? Ink.paper.opacity(0.7) : Ink.inkFaint.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(Capsule(style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
        .clipShape(.capsule(style: .continuous))
        .animation(Ink.Motion.settle, value: index)
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let fromTop = Int((drag.location.y / step).rounded(.down))
                    pick(stops.count - 1 - fromTop)
                }
        )
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stops.indices.reversed(), id: \.self) { at in
                Button {
                    pick(at)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stops[at].name)
                            .font(.system(size: Ink.Size.sub, weight: at == index ? .semibold : .regular))
                            .foregroundStyle(at == index ? Ink.ink : Ink.inkSoft)
                        if let detail = stops[at].detail {
                            Text(detail).font(.system(size: Ink.Size.micro)).foregroundStyle(Ink.inkFaint)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: step, maxHeight: step, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pick(_ at: Int) {
        let clamped = min(max(at, 0), stops.count - 1)
        guard stops.indices.contains(clamped), stops[clamped].value != value else { return }
        Haptics.tick(0.5)
        value = stops[clamped].value
    }
}

/// Helpers for settings stored before the stops existed (or set by hand): the stop nearest the stored number.
enum Stops {
    static func nearest(_ stored: Double, in values: [Double]) -> Double {
        values.min { abs($0 - stored) < abs($1 - stored) } ?? stored
    }

    static func nearest(_ stored: Int, in values: [Int]) -> Int {
        values.min { abs($0 - stored) < abs($1 - stored) } ?? stored
    }

    /// A binding that always reads as one of the stops, and writes the stop straight through.
    static func snapped(_ binding: Binding<Double>, to values: [Double]) -> Binding<Double> {
        Binding(get: { nearest(binding.wrappedValue, in: values) }, set: { binding.wrappedValue = $0 })
    }

    static func snapped(_ binding: Binding<Int>, to values: [Int]) -> Binding<Int> {
        Binding(get: { nearest(binding.wrappedValue, in: values) }, set: { binding.wrappedValue = $0 })
    }
}
