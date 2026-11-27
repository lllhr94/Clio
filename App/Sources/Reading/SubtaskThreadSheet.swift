import Craft
import SwiftUI

/// Inspects Canonical async subtask threads for a conversation, supporting cancellation,
/// clean retry for `.interrupted`, and explicit user confirmation for `.interruptedNeedsReconcile`.
struct SubtaskThreadSheet: View {
    @ObservedObject var team: TeamModel
    @ObservedObject var subtasks: SubtaskManager
    let parentChat: String
    @Environment(\.dismiss) private var dismiss
    @State private var reconcilingThread: SubtaskThread?
    @State private var errorNotice: String?

    private var items: [SubtaskThread] { subtasks.threads(for: parentChat) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ink.Space.m) {
                    if let errorNotice {
                        Text(errorNotice)
                            .font(Ink.footnote)
                            .foregroundStyle(Ink.stop)
                            .padding(.horizontal, Ink.Space.xs)
                    }
                    if items.isEmpty {
                        Text(L.t("subtask.empty"))
                            .font(Ink.secondary)
                            .foregroundStyle(Ink.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Ink.Space.l)
                            .paperCard()
                    } else {
                        ForEach(items) { thread in
                            threadCard(thread)
                        }
                    }
                }
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("subtask.sheetTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) { dismiss() }
                }
            }
            .confirmationDialog(
                L.t("subtask.reconcileConfirmTitle"),
                isPresented: Binding(
                    get: { reconcilingThread != nil },
                    set: { if !$0 { reconcilingThread = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L.t("subtask.reconcileConfirmAction"), role: .destructive) {
                    if let target = reconcilingThread {
                        reconcilingThread = nil
                        do {
                            try subtasks.retryThread(target.threadID, explicitUserReconciled: true, team: team)
                            errorNotice = nil
                        } catch {
                            errorNotice = error.localizedDescription
                        }
                    }
                }
                Button(L.t("actions.cancel"), role: .cancel) { reconcilingThread = nil }
            } message: {
                Text(L.t("subtask.reconcileConfirmBody"))
            }
        }
    }

    private func threadCard(_ thread: SubtaskThread) -> some View {
        let attempt = thread.latestAttempt
        return VStack(alignment: .leading, spacing: Ink.Space.s) {
            HStack(spacing: Ink.Space.s) {
                Text(thread.helperBotName)
                    .font(Ink.label)
                    .foregroundStyle(Ink.ink)
                statusBadge(thread.status)
                if thread.inheritedPlanMode {
                    Text(L.t("plan.modeTitle"))
                        .font(.system(size: Ink.Size.micro, weight: .medium))
                        .foregroundStyle(Ink.accent)
                        .padding(.horizontal, Ink.Space.xs)
                        .padding(.vertical, 2)
                        .background(Ink.accentWash, in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
            }

            Text(thread.taskPrompt)
                .font(Ink.secondary)
                .foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if let effects = attempt?.pendingSideEffects, !effects.isEmpty {
                VStack(alignment: .leading, spacing: Ink.Space.xs) {
                    Text(L.t("subtask.pendingEffectsHeader"))
                        .font(.system(size: Ink.Size.micro, weight: .semibold))
                        .foregroundStyle(Ink.warn)
                    ForEach(effects, id: \.callID) { effect in
                        Text("• \(effect.tool): \(effect.target)")
                            .font(Ink.mono(Ink.Size.micro))
                            .foregroundStyle(Ink.inkSoft)
                    }
                }
            }

            if let result = attempt?.resultText, !result.isEmpty {
                Text(result)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.ink)
                    .lineLimit(4)
            } else if let err = attempt?.errorMessage, !err.isEmpty {
                Text(err)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.stop)
            }

            HStack(spacing: Ink.Space.s) {
                if thread.status.isActive {
                    Button(L.t("subtask.cancelOne"), role: .destructive) {
                        Haptics.lock()
                        subtasks.cancelThread(thread.threadID, team: team)
                    }
                    .font(.system(size: Ink.Size.small, weight: .medium))
                } else if thread.status == .interrupted {
                    Button(L.t("subtask.retryClean")) {
                        Haptics.light()
                        do {
                            try subtasks.retryThread(thread.threadID, explicitUserReconciled: false, team: team)
                            errorNotice = nil
                        } catch {
                            errorNotice = error.localizedDescription
                        }
                    }
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                } else if thread.status == .interruptedNeedsReconcile {
                    Button(L.t("subtask.reconcileAndRetry")) {
                        Haptics.light()
                        reconcilingThread = thread
                    }
                    .font(.system(size: Ink.Size.small, weight: .semibold))
                    .foregroundStyle(Ink.warn)
                }
            }
        }
        .padding(Ink.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func statusBadge(_ status: SubtaskStatus) -> some View {
        let (titleKey, tint): (String, Color) = {
            switch status {
            case .queued, .running: return ("subtask.statusRunning", Ink.accent)
            case .waitingApproval, .waitingQuestion: return ("subtask.statusWaiting", Ink.warn)
            case .succeeded: return ("subtask.statusDone", Ink.ok)
            case .failed: return ("subtask.statusFailed", Ink.stop)
            case .cancelled: return ("subtask.statusCancelled", Ink.inkSoft)
            case .interrupted: return ("subtask.statusInterrupted", Ink.inkSoft)
            case .interruptedNeedsReconcile: return ("subtask.statusNeedsReconcile", Ink.warn)
            }
        }()
        return Text(L.t(titleKey))
            .font(.system(size: Ink.Size.micro, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Ink.Space.s)
            .padding(.vertical, 2)
            .background(Ink.surfaceSubtle, in: Capsule(style: .continuous))
    }
}
