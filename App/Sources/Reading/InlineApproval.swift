import SwiftUI

/// An approval answered where it is asked: what it wants to do, the command in full (scrolls, never cut),
/// and two buttons. "以后都允许" is a quieter text button so it is not pressed by habit.
struct InlineApproval: View {
    let approval: Approval
    @ObservedObject var team: TeamModel
    let name: String
    /// Opens the full slip.
    var more: () -> Void

    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.s) {
                Image(systemName: "seal").foregroundStyle(Ink.warn)
                Text("\(name)想\(approval.tool ?? "做一件事")，可以吗？")
                    .font(.system(size: Ink.Size.sub, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    Haptics.light()
                    more()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkFaint)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看完整的单子")
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(3)
            }
            if let well = approval.detail?.code ?? approval.detail?.text, !well.isEmpty {
                ScrollView([.vertical]) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(well)
                            .font(Ink.mono(Ink.Size.small))
                            .foregroundStyle(Ink.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(Ink.Space.s)
                    }
                }
                .frame(maxHeight: 6 * 16 + 12)
                .fixedSize(horizontal: false, vertical: true)
                .background(Ink.mine, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            }
            if let note {
                Text(note).font(Ink.footnote).foregroundStyle(Ink.stop)
            }
            HStack(spacing: Ink.Space.s) {
                if approval.toolName != nil, approval.forced != true {
                    Button("以后都允许") { decide(true, always: true) }
                        .font(.system(size: Ink.Size.small))
                        .foregroundStyle(Ink.inkSoft)
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityHint("这类事以后不再问")
                }
                Spacer(minLength: 0)
                Button("不批准") { decide(false) }
                    .buttonStyle(.bordered)
                    .tint(Ink.inkSoft)
                    .disabled(busy)
                Button("准这一次") { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.accent)
                    .disabled(busy)
            }
            .controlSize(.small)
        }
        .padding(Ink.Space.m)
        .paperCard()
    }

    private func decide(_ allow: Bool, always: Bool = false) {
        guard !busy else { return }
        busy = true
        allow ? Haptics.grab() : Haptics.light()
        Task {
            do {
                try await team.answer(approval, allow: allow, always: always)
            } catch {
                note = error.localizedDescription
                busy = false
            }
        }
    }
}
