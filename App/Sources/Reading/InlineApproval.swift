import Craft
import SwiftUI

enum InlineApprovalPolicy {
    static func canAnswer(answerable: Bool, forced: Bool, tool: String?, hasCode: Bool) -> Bool {
        guard answerable else { return false }
        if forced, let tool, ["shell", "ssh_run", "ssh_job_start", "run_js"].contains(tool) { return hasCode }
        return true
    }
}

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

    private var readOutside: Bool { approval.detail?.text?.hasPrefix(Taint.reason) == true }

    private var detailText: String? {
        guard let text = approval.detail?.text else { return nil }
        let words = readOutside ? String(text.dropFirst(Taint.reason.count)) : text
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
                .accessibilityLabel(L.t("approval.inlineDetails"))
            }
            if approval.forced == true {
                Label(L.t(readOutside ? "approval.webRequiresApproval" : "approval.alwaysAsks"),
                      systemImage: "exclamationmark.shield.fill")
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Ink.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.warn.opacity(0.12), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            }
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason).font(Ink.footnote).foregroundStyle(Ink.inkSoft).lineLimit(3)
            }
            if detailText != nil || approval.detail?.code?.isEmpty == false {
                ScrollView {
                    VStack(alignment: .leading, spacing: Ink.Space.s) {
                        if let detailText {
                            Text(detailText).font(Ink.footnote)
                        }
                        if let code = approval.detail?.code, !code.isEmpty {
                            Text(code).font(Ink.mono(Ink.Size.small))
                        }
                    }
                    .foregroundStyle(Ink.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Ink.Space.s)
                }
                .frame(maxHeight: 108 * UIScale.factor)
                .fixedSize(horizontal: false, vertical: true)
                .background(Ink.mine, in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            }
            if let note {
                Text(note).font(Ink.footnote).foregroundStyle(Ink.stop)
            }
            HStack(spacing: Ink.Space.s) {
                Spacer(minLength: 0)
                Button(L.t("actions.rejectApproval")) { decide(false) }
                    .buttonStyle(.bordered)
                    .tint(Ink.inkSoft)
                    .disabled(busy)
                Button(L.t("approval.inlineOnce")) { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.accent)
                    .disabled(busy)
            }
            .controlSize(.small)
            if approval.forced != true {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Ink.Space.m) { permissionChoices }
                    VStack(alignment: .leading, spacing: Ink.Space.s) { permissionChoices }
                }
                .font(Ink.footnote)
                .foregroundStyle(Ink.inkSoft)
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(Ink.Space.m)
        .paperCard()
    }

    @ViewBuilder
    private var permissionChoices: some View {
        if approval.chat != nil {
            Button(L.t("approval.inlineTrust")) { decide(true, trustChat: true) }
                .accessibilityHint(L.t("approval.inlineTrustHint"))
        }
        if approval.toolName != nil {
            Button(L.t("actions.allowAlways")) { decide(true, always: true) }
        }
    }

    private func decide(_ allow: Bool, always: Bool = false, trustChat: Bool = false) {
        guard !busy else { return }
        busy = true
        allow ? Haptics.grab() : Haptics.light()
        Task {
            do {
                try await team.answer(approval, allow: allow, always: always, trustChat: trustChat)
            } catch {
                note = error.localizedDescription
                busy = false
            }
        }
    }
}
