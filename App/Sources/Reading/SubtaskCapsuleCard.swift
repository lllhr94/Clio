import Craft
import SwiftUI

/// Compact pill above the chat composer when background companion subtasks are running or need reconciliation.
struct SubtaskCapsuleCard: View {
    let threads: [SubtaskThread]
    let onOpen: () -> Void

    private var activeCount: Int { threads.filter { $0.status.isActive }.count }
    private var reconcileCount: Int { threads.filter { $0.status == .interruptedNeedsReconcile }.count }
    private var interruptedCount: Int { threads.filter { $0.status == .interrupted }.count }

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            HStack(spacing: Ink.Space.xs) {
                Image(systemName: iconName)
                    .font(.system(size: Ink.Size.micro, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(headline)
                    .font(.system(size: Ink.Size.micro, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Kit.chevron
            }
            .padding(.horizontal, Ink.Space.m)
            .padding(.vertical, Ink.Space.xs)
            .background(Ink.surfaceSubtle, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accentColor.opacity(0.28), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if reconcileCount > 0 { return "exclamationmark.triangle" }
        if activeCount > 0 { return "arrow.triangle.branch" }
        return "arrow.clockwise"
    }

    private var accentColor: Color {
        if reconcileCount > 0 { return Ink.warn }
        if activeCount > 0 { return Ink.accent }
        return Ink.inkSoft
    }

    private var headline: String {
        if activeCount > 0 && reconcileCount > 0 {
            return L.format("subtask.capsuleActiveAndReconcile", activeCount, reconcileCount)
        }
        if activeCount > 0 {
            return L.format("subtask.capsuleActive", activeCount)
        }
        if reconcileCount > 0 {
            return L.format("subtask.capsuleNeedsReconcile", reconcileCount)
        }
        return L.format("subtask.capsuleInterrupted", interruptedCount)
    }
}
