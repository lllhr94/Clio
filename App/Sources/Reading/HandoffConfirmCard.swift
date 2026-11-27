import SwiftUI

/// Inline handoff card shown inside Casual Track when a heavier task should transition into formal chat.
struct HandoffConfirmCard: View {
    let summary: String
    let botName: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.m) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: Ink.Size.body, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                Text(L.t("casual.handoffTitle"))
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
            }

            Text(summary)
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Ink.Space.s) {
                Button {
                    Haptics.thud()
                    onConfirm()
                } label: {
                    Text(L.format("casual.handoffConfirm", botName))
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                        .background(Ink.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(PressStyle())

                Button {
                    Haptics.light()
                    onDismiss()
                } label: {
                    Text(L.t("casual.handoffStay"))
                        .font(.system(size: Ink.Size.small, weight: .medium))
                        .foregroundStyle(Ink.inkSoft)
                        .padding(.horizontal, Ink.Space.m)
                        .padding(.vertical, Ink.Space.s)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}
