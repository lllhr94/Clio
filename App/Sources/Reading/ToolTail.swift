import SwiftUI

/// What the command running right now is printing, a few lines at a time, for the status under the newest message.
@MainActor
final class ToolTail: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private nonisolated let buffer = Buffer()

    /// The producer keeps only the newest lines and schedules at most one UI update per burst.
    nonisolated func add(_ text: String) {
        guard buffer.append(text) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let pending = buffer.drain()
            if !pending.isEmpty { lines = Array((lines + pending.map { Line(text: $0) }).suffix(5)) }
        }
    }

    func clear() {
        lines = []
        buffer.clear()
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String] = []
        private var scheduled = false

        func append(_ text: String) -> Bool {
            lock.withLock {
                if pending.count == 5 { pending.removeFirst() }
                pending.append(text)
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
        }

        func drain() -> [String] {
            lock.withLock {
                defer { pending.removeAll(keepingCapacity: true); scheduled = false }
                return pending
            }
        }

        func clear() { lock.withLock { pending.removeAll(keepingCapacity: true) } }
    }
}

/// The last few lines a running command printed.
struct ToolTailView: View {
    @ObservedObject var tail: ToolTail

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
