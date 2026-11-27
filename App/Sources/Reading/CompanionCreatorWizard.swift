import SwiftUI

/// A local guided interview. Answers become an editable draft without a model request.
struct CompanionCreatorWizard: View {
    let onDraft: (BotInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.name
    @State private var answers: [Step: String] = [:]

    private enum Step: Int, CaseIterable {
        case name, role, relationship, expressionStyle, expertiseBoundary, privateNotes, publicAgentsCard

        var key: String { "persona.ask." + String(describing: self) }
    }

    private var answer: Binding<String> {
        Binding(get: { answers[step] ?? "" }, set: { answers[step] = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Ink.Space.l) {
                    ForEach(Step.allCases.prefix(step.rawValue + 1), id: \.self) { item in
                        Text(L.t(item.key))
                            .font(Ink.reading)
                            .foregroundStyle(Ink.ink)
                            .padding(Ink.Space.m)
                            .paperCard()
                        if item == step {
                            TextField(L.t("persona.answer"), text: answer, axis: .vertical)
                                .font(Ink.reading)
                                .lineLimit(2...5)
                                .paperField(height: nil)
                        } else if let value = value(item) {
                            Text(value)
                                .font(Ink.reading)
                                .foregroundStyle(Ink.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    Button(step == .publicAgentsCard ? L.t("persona.reviewDraft") : L.t("persona.next")) {
                        advance()
                    }
                    .buttonStyle(WideButtonStyle())
                    .disabled(step == .name && value(.name) == nil)
                    if let previous = Step(rawValue: step.rawValue - 1) {
                        Button(L.t("persona.previous")) { step = previous }
                            .buttonStyle(WideButtonStyle(filled: false))
                    }
                }
                .padding(Ink.Space.page)
            }
            .defaultScrollAnchor(.bottom)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("persona.wizard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("actions.cancel")) { dismiss() }
                }
            }
        }
    }

    private func value(_ item: Step) -> String? {
        let trimmed = answers[item]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
            return
        }
        guard let name = value(.name) else { return }
        onDraft(BotInfo(id: UUID().uuidString, name: name, role: value(.role),
                        relationship: value(.relationship), expressionStyle: value(.expressionStyle),
                        expertiseBoundary: value(.expertiseBoundary), privateNotes: value(.privateNotes),
                        publicAgentsCard: value(.publicAgentsCard)))
        dismiss()
    }
}
