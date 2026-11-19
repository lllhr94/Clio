import SwiftUI

/// A companion's short question (ask_user with nothing secret), answered in the conversation itself:
/// a few fields, choices as chips, and 递回去. Anything with a password still goes to the full slip.
struct InlineAsk: View {
    let form: Asker.Form
    @State private var values: [String: String] = [:]

    init(form: Asker.Form) {
        self.form = form
        _values = State(initialValue: Dictionary(form.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Ink.accent)
                Text("\(form.from)问：\(form.title)")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
            }
            if !form.reason.isEmpty {
                Text(form.reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft)
            }
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    if form.fields.count > 1 || !field.choices.isEmpty {
                        Text(field.label).font(.system(size: Ink.Size.small)).foregroundStyle(Ink.inkSoft)
                    }
                    if field.choices.isEmpty {
                        TextField(field.placeholder.isEmpty ? field.label : field.placeholder, text: binding(field.key), axis: .vertical)
                            .lineLimit(1...4)
                            .paperField()
                    } else {
                        FlowChips(choices: field.choices, picked: values[field.key] ?? "") { choice in
                            Haptics.tick(0.4)
                            values[field.key] = choice
                        }
                    }
                }
            }
            HStack {
                Button("不填") {
                    Haptics.light()
                    Asker.shared.cancel()
                }
                .foregroundStyle(Ink.inkSoft)
                .buttonStyle(.plain)
                Spacer()
                Button("递回去") {
                    Haptics.grab()
                    Asker.shared.answer(values)
                }
                .buttonStyle(.borderedProminent)
                .tint(Ink.accent)
                .disabled(form.fields.allSatisfy { (values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
            .font(.system(size: Ink.Size.sub, weight: .semibold))
        }
        .padding(Ink.Space.l)
        .paperCard()
        .onAppear { Asker.shared.inlineSeen = true }
        .onDisappear { Asker.shared.inlineSeen = false }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

/// Choices that wrap onto more lines when they don't fit.
private struct FlowChips: View {
    let choices: [String]
    let picked: String
    let pick: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                Button { pick(choice) } label: {
                    Text(choice)
                        .font(.system(size: Ink.Size.sub, weight: .medium))
                        .foregroundStyle(choice == picked ? Ink.paper : Ink.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(choice == picked ? Ink.accent : Ink.mine, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
