import SwiftUI

/// What the command running right now is printing, a few lines at a time, for the status under the newest message.
@MainActor
final class ToolTail: ObservableObject {
    nonisolated static let shared = ToolTail()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private var pending: [String] = []
    private var flushing = false

    nonisolated init() {}

    /// Lines come in quick bursts; they are shown at most every 150 ms so the screen stays smooth.
    nonisolated func add(_ text: String) {
        Task { @MainActor in self.queue(text) }
    }

    private func queue(_ text: String) {
        pending.append(text)
        guard !flushing else { return }
        flushing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            lines = Array((lines + pending.map { Line(text: $0) }).suffix(5))
            pending = []
            flushing = false
        }
    }

    func clear() {
        lines = []
        pending = []
    }
}

/// The last few lines a running command printed.
struct ToolTailView: View {
    @ObservedObject private var tail = ToolTail.shared

    var body: some View {
        if !tail.lines.isEmpty {
            VStack(alignment: .leading, spacing: Ink.Space.xs / 2) {
                ForEach(tail.lines) { line in
                    Text(line.text)
                        .font(Ink.mono(Ink.Size.micro))
                        .foregroundStyle(Ink.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(Ink.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.mine.opacity(0.6), in: .rect(cornerRadius: Ink.Radius.small, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: tail.lines)
            .accessibilityLabel("正在输出：" + (tail.lines.last?.text ?? ""))
        }
    }
}
