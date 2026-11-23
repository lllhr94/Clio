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
        // Pinned to the value at the row's right end, where the thumb taps, not the middle of the row; it keeps
        // the left of the page (a preview of the text, the pet) in view while dragging.
        .popover(isPresented: $open, attachmentAnchor: .point(UnitPoint(x: 0.92, y: 0.5))) {
            // No title inside: the row it opens from already says what it is, and the card stays short enough
            // to fit above or below the row (the system picks the side with room).
            ViewThatFits(in: .vertical) {
                StopRuler(value: $value, stops: stops, name: title)
                    .fixedSize()
                ScrollView(.vertical, showsIndicators: false) {
                    StopRuler(value: $value, stops: stops, name: title)
                }
                .frame(maxHeight: 340)
            }
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
    /// What VoiceOver calls it when no title is shown.
    var name: String? = nil

    /// Long rulers (a pet's ten sizes, a model's eight windows) use shorter stops so the card stays on screen.
    private var step: CGFloat { (stops.count > 6 ? 28 : 32) * UIScale.factor }
    /// A slim bar: the names do the telling, the bar is what the thumb runs along.
    private var width: CGFloat { 26 * UIScale.factor }
    private var index: Int { stops.firstIndex { $0.value == value } ?? 0 }

    // 主人定: names on the left, the bar on the right where the right thumb is; a small card with room around the
    // bar, so it never touches the card's edges.
    var body: some View {
        VStack(alignment: .trailing, spacing: Ink.Space.s) {
            if let title {
                Text(title).font(.system(size: Ink.Size.small, weight: .semibold)).foregroundStyle(Ink.inkSoft)
            }
            HStack(alignment: .top, spacing: Ink.Space.l) {
                column(alignment: .leading) { at in
                    Text(stops[at].name)
                        .font(.system(size: Ink.Size.sub, weight: at == index ? .semibold : .regular))
                        .foregroundStyle(at == index ? Ink.accent : Ink.inkSoft)
                }
                if stops.contains(where: { $0.detail != nil }) {
                    column(alignment: .trailing) { at in
                        Text(stops[at].detail ?? "")
                            .font(.system(size: Ink.Size.small).monospacedDigit())
                            .foregroundStyle(at == index ? Ink.accent : Ink.inkFaint)
                    }
                }
                capsule
            }
        }
        .padding(Ink.Space.l)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? name ?? "")
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
        let filled = step * (CGFloat(index) + 0.5) + width / 2
        return ZStack(alignment: .bottom) {
            Capsule(style: .continuous).fill(Ink.rule.opacity(0.55))
            Capsule(style: .continuous)
                .fill(Ink.accent)
                .frame(height: min(height, max(width, filled)))
                .overlay(alignment: .top) {
                    // The handle: a short pale line at the top of the ink, where the thumb holds it.
                    Capsule().fill(Ink.paper.opacity(0.85)).frame(width: width * 0.45, height: 3).padding(.top, width * 0.35)
                }
        }
        .frame(width: width, height: height)
        .clipShape(.capsule(style: .continuous))
        .animation(Ink.Motion.settle, value: index)
        .contentShape(.rect.inset(by: -Ink.Space.s))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let fromTop = Int((drag.location.y / step).rounded(.down))
                    pick(stops.count - 1 - fromTop)
                }
        )
    }

    /// One column of the table: names lined up on the left, the numbers on the right, each row as tall as its
    /// stop on the bar, so the three columns read straight across (主人定: tidy, symmetric).
    private func column<Cell: View>(alignment: HorizontalAlignment, @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(stops.indices.reversed(), id: \.self) { at in
                Button {
                    pick(at)
                } label: {
                    cell(at)
                        .lineLimit(1)
                        .frame(minHeight: step, maxHeight: step)
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
